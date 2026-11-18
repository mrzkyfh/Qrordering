-- QR Ordering: klaim QRIS manual dan relasi pesanan tambahan.
-- Semua mutasi sensitif dilakukan melalui RPC SECURITY DEFINER; tabel tidak
-- menerima INSERT/UPDATE langsung dari anon maupun authenticated.

DO $$ BEGIN
  CREATE TYPE public.payment_claim_status AS ENUM (
    'PENDING', 'WAITING_VERIFICATION', 'PAID', 'VERIFICATION_FAILED',
    'EXPIRED', 'CANCELLED', 'REFUNDED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.payment_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  status public.payment_claim_status NOT NULL DEFAULT 'PENDING',
  proof_url TEXT,
  submitted_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (order_id),
  CHECK (proof_url IS NULL OR (length(proof_url) <= 2048 AND proof_url ~ '^https://')),
  CHECK (rejection_reason IS NULL OR length(rejection_reason) <= 500)
);

CREATE INDEX IF NOT EXISTS idx_payment_claims_outlet_status
  ON public.payment_claims(outlet_id, status, submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_payment_claims_expiry
  ON public.payment_claims(expires_at)
  WHERE status IN ('PENDING', 'WAITING_VERIFICATION');

ALTER TABLE public.payment_claims ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payment_claims_select ON public.payment_claims;
CREATE POLICY payment_claims_select ON public.payment_claims
FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.is_active
      AND (p.role = 'owner' OR p.outlet_id = payment_claims.outlet_id)
  )
);

REVOKE ALL ON TABLE public.payment_claims FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.payment_claims TO authenticated;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS parent_order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_orders_parent_order ON public.orders(parent_order_id)
  WHERE parent_order_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.assign_additional_order_parent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.parent_order_id IS NULL AND NEW.table_id IS NOT NULL
     AND NEW.order_type = 'self_order' THEN
    SELECT o.id INTO NEW.parent_order_id
    FROM public.orders o
    WHERE o.outlet_id = NEW.outlet_id
      AND o.table_id = NEW.table_id
      AND o.id <> NEW.id
      AND o.parent_order_id IS NULL
      AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
    ORDER BY o.created_at DESC
    LIMIT 1;
  END IF;
  IF NEW.parent_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders parent
    WHERE parent.id = NEW.parent_order_id
      AND parent.outlet_id = NEW.outlet_id
      AND parent.table_id IS NOT DISTINCT FROM NEW.table_id
  ) THEN
    RAISE EXCEPTION 'Pesanan tambahan harus berada pada outlet dan meja yang sama'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assign_additional_order_parent ON public.orders;
CREATE TRIGGER trg_assign_additional_order_parent
BEFORE INSERT OR UPDATE OF parent_order_id, table_id ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.assign_additional_order_parent();

CREATE OR REPLACE FUNCTION public.submit_qris_payment_claim(
  p_order_id UUID,
  p_table_token TEXT,
  p_proof_url TEXT DEFAULT NULL
)
RETURNS public.payment_claims
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_timeout INTEGER;
  v_claim public.payment_claims%ROWTYPE;
BEGIN
  IF p_order_id IS NULL OR p_table_token IS NULL OR length(p_table_token) < 16 THEN
    RAISE EXCEPTION 'Order atau token meja tidak valid' USING ERRCODE = '22023';
  END IF;
  SELECT o.* INTO v_order
  FROM public.orders o
  JOIN public.restaurant_tables t ON t.id = o.table_id
  WHERE o.id = p_order_id AND t.qr_token = p_table_token AND t.is_active
  FOR UPDATE OF o;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order atau sesi meja tidak valid' USING ERRCODE = '42501'; END IF;
  IF v_order.status NOT IN ('draft', 'confirmed') THEN
    RAISE EXCEPTION 'Order tidak dapat mengajukan pembayaran pada status ini' USING ERRCODE = '22023';
  END IF;
  SELECT GREATEST(1, LEAST(120, COALESCE((settings->>'payment_timeout_minutes')::INTEGER, 15)))
    INTO v_timeout FROM public.outlets WHERE id = v_order.outlet_id;

  INSERT INTO public.payment_claims(order_id, outlet_id, status, proof_url, submitted_at, expires_at)
  VALUES (v_order.id, v_order.outlet_id, 'WAITING_VERIFICATION', NULLIF(trim(p_proof_url), ''), now(), now() + make_interval(mins => v_timeout))
  ON CONFLICT (order_id) DO UPDATE SET
    status = 'WAITING_VERIFICATION', proof_url = EXCLUDED.proof_url,
    submitted_at = now(), expires_at = EXCLUDED.expires_at,
    reviewed_by = NULL, reviewed_at = NULL, rejection_reason = NULL, updated_at = now()
  WHERE payment_claims.status IN ('PENDING', 'VERIFICATION_FAILED', 'EXPIRED')
  RETURNING * INTO v_claim;
  IF v_claim.id IS NULL THEN
    RAISE EXCEPTION 'Klaim pembayaran sudah diproses atau dibatalkan' USING ERRCODE = '22023';
  END IF;
  RETURN v_claim;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_qris_payment_claim(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_qris_payment_claim(UUID, TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.review_qris_payment_claim(
  p_claim_id UUID,
  p_decision public.payment_claim_status,
  p_reason TEXT DEFAULT NULL
)
RETURNS public.payment_claims
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claim public.payment_claims%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_actor public.profiles%ROWTYPE;
  v_paid NUMERIC;
BEGIN
  SELECT * INTO v_actor FROM public.profiles WHERE id = auth.uid() AND is_active;
  IF v_actor.id IS NULL OR v_actor.role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang memverifikasi pembayaran' USING ERRCODE = '42501';
  END IF;
  IF p_decision NOT IN ('PAID', 'VERIFICATION_FAILED', 'CANCELLED') THEN
    RAISE EXCEPTION 'Keputusan verifikasi tidak valid' USING ERRCODE = '22023';
  END IF;
  IF p_decision <> 'PAID' AND length(trim(COALESCE(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'Alasan penolakan atau pembatalan wajib diisi' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_claim FROM public.payment_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Klaim tidak ditemukan' USING ERRCODE = 'P0002'; END IF;
  IF v_actor.role <> 'owner' AND v_actor.outlet_id IS DISTINCT FROM v_claim.outlet_id THEN
    RAISE EXCEPTION 'Klaim berasal dari outlet lain' USING ERRCODE = '42501';
  END IF;
  IF v_claim.status NOT IN ('PENDING', 'WAITING_VERIFICATION') THEN
    RAISE EXCEPTION 'Klaim sudah diproses' USING ERRCODE = '22023';
  END IF;
  IF v_claim.expires_at <= now() THEN p_decision := 'EXPIRED'; END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_claim.order_id FOR UPDATE;
  IF p_decision = 'PAID' THEN
    SELECT COALESCE(sum(amount), 0) INTO v_paid FROM public.payments WHERE order_id = v_order.id;
    IF v_order.total_amount - v_paid <= 0 THEN
      RAISE EXCEPTION 'Order sudah lunas' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.payments(order_id, outlet_id, method, amount, reference_number, paid_at)
    VALUES (v_order.id, v_order.outlet_id, 'qris', v_order.total_amount - v_paid, 'claim:' || v_claim.id::TEXT, now());
    PERFORM public.finalize_split_payment(v_order.id);
  END IF;

  UPDATE public.payment_claims SET status = p_decision, reviewed_by = v_actor.id,
    reviewed_at = now(), rejection_reason = CASE WHEN p_decision = 'PAID' THEN NULL ELSE trim(p_reason) END,
    updated_at = now()
  WHERE id = v_claim.id RETURNING * INTO v_claim;

  INSERT INTO public.order_audit_log(order_id, outlet_id, actor_id, actor_name, action, old_value, new_value, notes)
  VALUES (v_order.id, v_order.outlet_id, v_actor.id, v_actor.full_name, 'payment_verification',
    jsonb_build_object('status', 'WAITING_VERIFICATION'), jsonb_build_object('status', p_decision), p_reason);
  RETURN v_claim;
END;
$$;

REVOKE ALL ON FUNCTION public.review_qris_payment_claim(UUID, public.payment_claim_status, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_qris_payment_claim(UUID, public.payment_claim_status, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.expire_qris_payment_claims()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count INTEGER;
BEGIN
  UPDATE public.payment_claims SET status = 'EXPIRED', updated_at = now()
  WHERE status IN ('PENDING', 'WAITING_VERIFICATION') AND expires_at <= now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_qris_payment_claims() FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.payment_claims IS 'Klaim pembayaran QRIS statis yang wajib diverifikasi manual oleh petugas.';
COMMENT ON COLUMN public.orders.parent_order_id IS 'Pesanan utama untuk pesanan tambahan pada meja yang sama.';

-- 134_owner_pos_transaction_authority.sql
--
-- Menutup celah role pada transaksi POS:
--   1. Owner boleh membuat order lintas outlet.
--   2. Owner boleh menulis order_items, options, dan payments untuk order
--      outlet yang dipilih; outlet payment wajib sama dengan outlet order.
--   3. Nomor order POS memakai wrapper berizin. Function counter lama tetap
--      tertutup untuk pemanggilan REST langsung dan tetap bisa dipanggil oleh
--      RPC self-order SECURITY DEFINER.
--   4. Payment dicatat melalui RPC yang memeriksa order/outlet/role dan dapat
--      melunasi order hanya bila jumlah payment sudah menutup total.

-- ── 1. POS order-number wrapper ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_next_pos_order_number(p_outlet_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_outlet_id IS NULL THEN
    RAISE EXCEPTION 'Outlet wajib dipilih' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.outlets
    WHERE id = p_outlet_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Outlet tidak aktif atau tidak ditemukan'
      USING ERRCODE = '22023';
  END IF;

  -- Owner lintas outlet; role lain hanya outlet yang melekat pada profilnya.
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir')
     OR NOT (
       COALESCE(public.is_owner(), false)
       OR p_outlet_id = public.auth_outlet_id()
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang membuat transaksi di outlet ini'
      USING ERRCODE = '42501';
  END IF;

  RETURN public.get_next_order_number(p_outlet_id);
END;
$$;

REVOKE ALL ON FUNCTION public.get_next_pos_order_number(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_next_pos_order_number(UUID) TO authenticated;

COMMENT ON FUNCTION public.get_next_pos_order_number(UUID) IS
  'Nomor order POS dengan pemeriksaan outlet/role. Counter lama hanya dipakai '
  'internal oleh RPC SECURITY DEFINER seperti self-order.';

-- Tutup counter lama dari pemanggilan REST langsung. Tanpa ini wrapper berizin
-- di atas bisa DILEWATI: siapa pun (bahkan anon) memanggil get_next_order_number
-- langsung → membakar nomor order outlet mana pun tanpa cek outlet/role. Semua
-- pemanggil sahnya SECURITY DEFINER (create_self_order 109/114/125/129 &
-- get_next_pos_order_number di atas) → berjalan sebagai owner, tak terdampak
-- pencabutan ini. Tak ada pemanggil klien langsung (mobile pakai wrapper baru).
REVOKE EXECUTE ON FUNCTION public.get_next_order_number(UUID)
  FROM PUBLIC, anon, authenticated;

-- ── 2. Role-aware write policies ────────────────────────────────────────────
DROP POLICY IF EXISTS "orders_insert" ON public.orders;
CREATE POLICY "orders_insert" ON public.orders
  FOR INSERT TO authenticated
  WITH CHECK (
    public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
    AND (public.is_owner() OR outlet_id = public.auth_outlet_id())
    AND (status IS NULL OR status IN ('draft', 'confirmed'))
    AND approved_by IS NULL
  );

DROP POLICY IF EXISTS "order_items_insert" ON public.order_items;
CREATE POLICY "order_items_insert" ON public.order_items
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

DROP POLICY IF EXISTS "payments_insert" ON public.payments;
CREATE POLICY "payments_insert" ON public.payments
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = payments.order_id
        AND o.outlet_id = payments.outlet_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

-- Tetapkan ulang policy options di sini agar hasil akhir tetap benar walau
-- database pernah berhenti sebelum migration 048.
DROP POLICY IF EXISTS "oio_insert_auth" ON public.order_item_options;
CREATE POLICY "oio_insert_auth" ON public.order_item_options
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      WHERE oi.id = order_item_options.order_item_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

-- ── 3. Server-authoritative POS payment ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_pos_payment(
  p_order_id UUID,
  p_outlet_id UUID,
  p_method public.payment_method,
  p_amount NUMERIC,
  p_reference_number TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_finalize BOOLEAN DEFAULT TRUE,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_payment_id UUID;
  v_paid NUMERIC;
  v_is_duplicate BOOLEAN := false;
BEGIN
  IF p_order_id IS NULL OR p_outlet_id IS NULL THEN
    RAISE EXCEPTION 'Order dan outlet wajib diisi' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Nominal pembayaran harus lebih dari 0'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.outlet_id <> p_outlet_id THEN
    RAISE EXCEPTION 'Order tidak ditemukan di outlet tersebut'
      USING ERRCODE = '22023';
  END IF;

  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir')
     OR NOT (
       COALESCE(public.is_owner(), false)
       OR v_order.outlet_id = public.auth_outlet_id()
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang membayar order ini'
      USING ERRCODE = '42501';
  END IF;

  -- Retry dengan idempotency key yang sama tidak boleh menambah payment kedua.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id
      INTO v_payment_id
    FROM public.payments
    WHERE order_id = p_order_id
      AND idempotency_key = p_idempotency_key;
    v_is_duplicate := v_payment_id IS NOT NULL;
  END IF;

  IF v_order.status IN ('cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;
  IF v_order.status = 'paid' AND NOT v_is_duplicate THEN
    RAISE EXCEPTION 'Order sudah lunas' USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_duplicate THEN
    INSERT INTO public.payments (
      order_id, outlet_id, method, amount, reference_number, paid_at,
      idempotency_key
    ) VALUES (
      p_order_id, p_outlet_id, p_method, p_amount, p_reference_number,
      COALESCE(p_paid_at, NOW()),
      p_idempotency_key
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_payment_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0)
    INTO v_paid
  FROM public.payments
  WHERE order_id = p_order_id;

  -- Split bill menunda perubahan status sampai finalize_split_payment.
  IF p_finalize AND v_paid + 1 >= v_order.total_amount THEN
    UPDATE public.orders
    SET status = 'paid', updated_at = NOW()
    WHERE id = p_order_id
      AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'paid_total', v_paid,
    'order_total', v_order.total_amount,
    'status', CASE
      WHEN p_finalize AND v_paid + 1 >= v_order.total_amount THEN 'paid'
      ELSE v_order.status::TEXT
    END,
    'duplicate', v_is_duplicate
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) TO authenticated;

COMMENT ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) IS
  'Catat payment POS secara idempoten dengan pemeriksaan role/outlet. Bila '
  'finalize=true, order hanya menjadi paid setelah payment menutup total.';

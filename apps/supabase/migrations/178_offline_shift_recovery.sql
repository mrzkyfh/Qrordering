-- 178_offline_shift_recovery.sql
--
-- Transaksi offline dapat membawa shift_id cache lama walaupun kasir memiliki
-- shift yang benar. Server tetap menjadi sumber kebenaran: pemetaan hanya
-- dilakukan ketika shift asal sudah tutup, transaksi terjadi setelah penutupan,
-- dan ada shift milik kasir shift asal yang mencakup waktu transaksi. Shift
-- pengganti boleh sudah ditutup ketika antrean akhirnya tersinkron; yang penting
-- waktu transaksi berada di dalam rentang shift tersebut. Shift asal disimpan
-- pada order untuk audit.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS original_shift_id UUID
    REFERENCES public.shifts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS shift_recovery_reason TEXT,
  ADD COLUMN IF NOT EXISTS shift_recovered_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_orders_original_shift_recovery
  ON public.orders(original_shift_id)
  WHERE original_shift_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.guard_order_shift_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role        TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_shift       public.shifts%ROWTYPE;
  v_replacement public.shifts%ROWTYPE;
BEGIN
  -- SQL administratif/service-role tanpa JWT tetap dapat melakukan maintenance.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.shift_id IS NULL THEN
    IF TG_OP = 'UPDATE' AND OLD.shift_id IS NOT NULL THEN
      RAISE EXCEPTION 'Till order tidak boleh dikosongkan'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang memakai till'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' AND NEW.created_at > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu transaksi perangkat terlalu jauh di masa depan'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = NEW.shift_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Till tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;

  IF v_shift.end_time IS NOT NULL THEN
    IF NEW.created_at >= v_shift.start_time
       AND NEW.created_at <= v_shift.end_time THEN
      -- Replay historis yang memang terjadi sebelum kasir menutup till sah dan
      -- tetap diatribusikan ke till aslinya.
      NULL;
    ELSIF TG_OP = 'INSERT' THEN
      SELECT * INTO v_replacement
      FROM public.shifts
      WHERE outlet_id = NEW.outlet_id
        AND kasir_id = v_shift.kasir_id
        AND start_time <= NEW.created_at
        AND (end_time IS NULL OR NEW.created_at <= end_time)
      ORDER BY start_time DESC
      LIMIT 1
      FOR KEY SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION
          'Till sudah ditutup dan tidak ada till yang sesuai waktu transaksi'
          USING ERRCODE = '22023';
      END IF;

      NEW.original_shift_id := NEW.shift_id;
      NEW.shift_id := v_replacement.id;
      NEW.shift_recovery_reason := 'stale_cached_shift';
      NEW.shift_recovered_at := now();
      v_shift := v_replacement;
    ELSE
      RAISE EXCEPTION 'Till sudah ditutup'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_role IN ('manajer', 'kasir')
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya boleh memakai till miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_order_shift_assignment() FROM PUBLIC;

-- Berlaku untuk seluruh jalur penulisan payment, termasuk RPC kompatibilitas
-- klien lama. paid_at harus benar-benar berada di dalam rentang till; hanya
-- memeriksa waktu tutup masih memungkinkan waktu sebelum till dibuka atau jam
-- perangkat jauh di masa depan ikut tercatat pada rekonsiliasi kas.
CREATE OR REPLACE FUNCTION public.guard_payment_shift()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role  TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_order public.orders%ROWTYPE;
  v_shift public.shifts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = NEW.order_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.paid_at > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu pembayaran perangkat terlalu jauh di masa depan'
      USING ERRCODE = '22023';
  END IF;

  IF NEW.shift_id IS NULL THEN
    IF NEW.method::TEXT = 'cash' THEN
      RAISE EXCEPTION 'Pembayaran tunai wajib memakai till'
        USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = NEW.shift_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Till pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.paid_at < v_shift.start_time THEN
    RAISE EXCEPTION 'Waktu pembayaran sebelum till dibuka'
      USING ERRCODE = '22023';
  END IF;
  IF v_shift.end_time IS NOT NULL AND NEW.paid_at > v_shift.end_time THEN
    RAISE EXCEPTION 'Till pembayaran sudah ditutup'
      USING ERRCODE = '22023';
  END IF;
  IF v_role IN ('manajer', 'kasir')
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION
      'Kasir hanya boleh menerima pembayaran pada till miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_payment_shift() FROM PUBLIC;

-- Payment replay masih mengirim shift_id dari payload lokal. Bila trigger di
-- atas telah memulihkan order, gunakan shift efektif pada order agar header dan
-- semua bagian split payment selalu masuk ke shift yang sama.
CREATE OR REPLACE FUNCTION public.record_pos_payment_with_context(
  p_order_id UUID,
  p_outlet_id UUID,
  p_shift_id UUID,
  p_force_order_shift BOOLEAN,
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
  v_shift public.shifts%ROWTYPE;
  v_effective_shift_id UUID := p_shift_id;
  v_result JSONB;
  v_payment_id UUID;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_paid_at TIMESTAMPTZ := COALESCE(p_paid_at, now());
BEGIN
  IF p_shift_id IS NULL THEN
    RAISE EXCEPTION 'Pembayaran wajib dihubungkan ke shift kasir'
      USING ERRCODE = '22023';
  END IF;
  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang menerima pembayaran'
      USING ERRCODE = '42501';
  END IF;
  IF v_paid_at > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu pembayaran perangkat terlalu jauh di masa depan'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Order tidak ditemukan di outlet tersebut'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Shift pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF v_paid_at < v_shift.start_time THEN
    RAISE EXCEPTION 'Waktu pembayaran sebelum till dibuka'
      USING ERRCODE = '22023';
  END IF;

  IF v_shift.end_time IS NOT NULL
     AND v_paid_at > v_shift.end_time THEN
    IF v_order.original_shift_id IS NOT DISTINCT FROM p_shift_id
       AND v_order.shift_recovery_reason = 'stale_cached_shift'
       AND v_order.shift_id IS DISTINCT FROM p_shift_id THEN
      v_effective_shift_id := v_order.shift_id;
      SELECT * INTO v_shift
      FROM public.shifts
      WHERE id = v_effective_shift_id;
    ELSE
      RAISE EXCEPTION 'Shift pembayaran sudah ditutup'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT FOUND
     OR v_shift.outlet_id IS DISTINCT FROM p_outlet_id
     OR v_paid_at < v_shift.start_time
     OR (
       v_shift.end_time IS NOT NULL
       AND v_paid_at > v_shift.end_time
     ) THEN
    RAISE EXCEPTION 'Shift pemulihan pembayaran tidak lagi aktif'
      USING ERRCODE = '22023';
  END IF;

  IF v_role IN ('manajer', 'kasir')
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION
      'Kasir hanya boleh menerima pembayaran pada shift miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  IF v_order.created_by IS NULL
     OR (
       COALESCE(p_force_order_shift, false)
       AND v_order.shift_id IS DISTINCT FROM v_effective_shift_id
     ) THEN
    PERFORM public.assign_order_payment_context(
      p_order_id,
      v_effective_shift_id,
      COALESCE(p_force_order_shift, false)
    );
  END IF;

  v_result := public.record_pos_payment_internal(
    p_order_id,
    p_outlet_id,
    v_effective_shift_id,
    p_method,
    p_amount,
    p_reference_number,
    p_idempotency_key,
    p_finalize,
    v_paid_at
  );

  v_payment_id := NULLIF(v_result->>'payment_id', '')::UUID;
  IF v_payment_id IS NOT NULL THEN
    UPDATE public.payments
    SET shift_id = v_effective_shift_id
    WHERE id = v_payment_id
      AND (
        NOT COALESCE((v_result->>'duplicate')::BOOLEAN, false)
        OR shift_id IS NULL
      );
  END IF;

  RETURN v_result || jsonb_build_object(
    'effective_shift_id', v_effective_shift_id,
    'shift_recovered', v_effective_shift_id IS DISTINCT FROM p_shift_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) TO authenticated;

COMMENT ON COLUMN public.orders.original_shift_id IS
  'Shift cache asal sebelum replay offline dipetakan ke shift aktif yang benar.';
COMMENT ON COLUMN public.orders.shift_recovery_reason IS
  'Alasan pemetaan shift oleh server; stale_cached_shift untuk cache perangkat lama.';
COMMENT ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) IS
  'Mencatat pembayaran dengan shift efektif order; mendukung audit pemulihan '
  'cache till lama, split payment, retry idempoten, dan replay offline.';

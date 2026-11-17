-- 182_enforce_payment_total_invariant.sql
--
-- Split payment harus menjaga invariant:
--   0 <= SUM(payments.amount) <= orders.total_amount
-- Pengecekan dilakukan setelah order dikunci dan setelah penyesuaian finansial
-- server, sehingga aman terhadap retry idempoten dan dua perangkat yang
-- membayar order yang sama secara bersamaan.

CREATE OR REPLACE FUNCTION public.record_pos_payment_internal(
  p_order_id UUID,
  p_outlet_id UUID,
  p_payment_shift_id UUID,
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
  v_paid NUMERIC := 0;
  v_is_duplicate BOOLEAN := false;
  v_will_be_paid BOOLEAN := false;
BEGIN
  IF p_order_id IS NULL OR p_outlet_id IS NULL
     OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Order, outlet, dan nominal pembayaran wajib valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
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

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_payment_id
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

  IF v_is_duplicate AND v_order.status = 'paid' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments
    WHERE order_id = p_order_id;
    RETURN jsonb_build_object(
      'payment_id', v_payment_id,
      'paid_total', v_paid,
      'order_total', v_order.total_amount,
      'status', 'paid',
      'duplicate', true
    );
  END IF;

  PERFORM public.validate_order_financial_integrity(p_order_id);
  IF p_finalize THEN
    PERFORM public.settle_pos_order_adjustments(p_order_id);
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;
    PERFORM public.validate_order_financial_integrity(p_order_id);
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments
  WHERE order_id = p_order_id;

  -- Retry dengan idempotency key yang sama tidak menambahkan nominal lagi.
  -- Pembayaran baru wajib muat tepat di dalam sisa tagihan.
  IF NOT v_is_duplicate AND v_paid + p_amount > v_order.total_amount THEN
    RAISE EXCEPTION
      'Pembayaran melebihi sisa tagihan (terbayar %, nominal %, total %)',
      v_paid, p_amount, v_order.total_amount
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_duplicate THEN
    INSERT INTO public.payments(
      order_id,
      outlet_id,
      shift_id,
      method,
      amount,
      reference_number,
      paid_at,
      idempotency_key
    ) VALUES (
      p_order_id,
      p_outlet_id,
      COALESCE(p_payment_shift_id, v_order.shift_id),
      p_method,
      p_amount,
      p_reference_number,
      COALESCE(p_paid_at, now()),
      p_idempotency_key
    )
    RETURNING id INTO v_payment_id;

    v_paid := v_paid + p_amount;
  END IF;

  v_will_be_paid := p_finalize AND v_paid = v_order.total_amount;
  IF v_will_be_paid THEN
    PERFORM set_config('app.order_status_mutation', 'on', true);
    UPDATE public.orders
    SET status = 'paid',
        updated_at = now()
    WHERE id = p_order_id
      AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'paid_total', v_paid,
    'order_total', v_order.total_amount,
    'status', CASE
      WHEN v_will_be_paid THEN 'paid'
      ELSE v_order.status::TEXT
    END,
    'duplicate', v_is_duplicate
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment_internal(
  UUID, UUID, UUID, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.finalize_split_payment(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_paid NUMERIC;
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR public.auth_outlet_id() IS NOT DISTINCT FROM v_order.outlet_id
  ) THEN
    RAISE EXCEPTION 'Tidak berwenang atas order ini' USING ERRCODE = '42501';
  END IF;
  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('status', 'paid', 'already', true);
  END IF;
  IF v_order.status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;

  PERFORM public.validate_order_financial_integrity(p_order_id);
  PERFORM public.settle_pos_order_adjustments(p_order_id);
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  PERFORM public.validate_order_financial_integrity(p_order_id);

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments
  WHERE order_id = p_order_id;

  IF v_paid < v_order.total_amount THEN
    RAISE EXCEPTION 'Pembayaran belum menutupi total (terbayar % dari %)',
      v_paid, v_order.total_amount USING ERRCODE = '22023';
  END IF;
  IF v_paid > v_order.total_amount THEN
    RAISE EXCEPTION 'Pembayaran melebihi total (terbayar % dari %)',
      v_paid, v_order.total_amount USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders
  SET status = 'paid', updated_at = now()
  WHERE id = p_order_id
    AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');

  RETURN jsonb_build_object(
    'status', 'paid',
    'paid_total', v_paid,
    'order_total', v_order.total_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_split_payment(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_split_payment(UUID) TO authenticated;

COMMENT ON FUNCTION public.finalize_split_payment(UUID) IS
  'Menyelesaikan split payment hanya bila total pembayaran tepat sama dengan '
  'total order; underpay dan overpay sama-sama ditolak.';

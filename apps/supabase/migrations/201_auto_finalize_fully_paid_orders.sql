-- 201_auto_finalize_fully_paid_orders.sql
--
-- Pembayaran split sebelumnya dicatat dengan p_finalize=false. Jika kasir
-- menutup sheet setelah pembayaran terakhir tetapi sebelum menekan tombol
-- finalisasi kedua, uang sudah masuk ke payments sementara status order tetap
-- aktif. Jadikan invariant server lebih kuat: ketika jumlah pembayaran tepat
-- sama dengan total order, status selalu menjadi paid dalam transaksi yang sama.

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
  v_should_settle BOOLEAN := false;
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

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments
  WHERE order_id = p_order_id;

  -- Selain permintaan finalisasi eksplisit, pembayaran yang mengisi tepat
  -- seluruh sisa tagihan juga harus menyelesaikan promo/loyalty dan order.
  -- Retry idempoten ikut menutup celah crash setelah INSERT payment lama.
  v_should_settle := p_finalize
    OR (v_is_duplicate AND v_paid = v_order.total_amount)
    OR (NOT v_is_duplicate AND v_paid + p_amount = v_order.total_amount);

  IF v_should_settle THEN
    PERFORM public.settle_pos_order_adjustments(p_order_id);
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;
    PERFORM public.validate_order_financial_integrity(p_order_id);

    -- Adjustment server dapat memutakhirkan total; baca ulang pembayaran
    -- sebelum memeriksa batas dan menentukan status akhir.
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments
    WHERE order_id = p_order_id;
  END IF;

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

  -- Status lunas diturunkan dari fakta pembayaran, bukan dari tombol kedua di
  -- klien. Underpay tetap aktif dan overpay sudah ditolak di atas.
  v_will_be_paid := v_paid = v_order.total_amount;
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

-- Rekonsiliasi data historis: hanya order aktif yang pembayaran brutonya tepat
-- sama dengan total. Order kurang bayar, lebih bayar, void, dan cancelled tidak
-- disentuh. Efek promo/loyalty historis juga tidak dihitung ulang agar promo
-- yang kini kedaluwarsa tidak menggagalkan pemulihan status transaksi lama.
DO $$
BEGIN
  PERFORM set_config('app.order_status_mutation', 'on', true);

  UPDATE public.orders AS o
  SET status = 'paid',
      updated_at = now()
  WHERE o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
    AND o.total_amount > 0
    AND (
      SELECT COALESCE(SUM(p.amount), 0)
      FROM public.payments AS p
      WHERE p.order_id = o.id
    ) = o.total_amount;
END;
$$;

COMMENT ON FUNCTION public.record_pos_payment_internal(
  UUID, UUID, UUID, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) IS
  'Mencatat pembayaran idempoten dan otomatis melunasi order ketika total '
  'payments tepat sama dengan total order, termasuk pembayaran split.';

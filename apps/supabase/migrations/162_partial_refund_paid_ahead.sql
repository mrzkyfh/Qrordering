-- 162_partial_refund_paid_ahead.sql
--
-- Order bayar-di-depan tetap berstatus confirmed/preparing/ready/served sampai
-- proses dapur selesai, tetapi total pembayarannya sudah menutup tagihan.
-- Mobile dengan benar menampilkan Refund Sebagian; RPC 142 keliru menolak
-- karena hanya memeriksa status='paid'.

CREATE OR REPLACE FUNCTION public.refund_order_items(
  p_order        UUID,
  p_items        JSONB,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_order    public.orders%ROWTYPE;
  v_approver UUID;
  v_refund   UUID;
  v_method   public.payment_method;
  v_paid     NUMERIC := 0;
  v_total    NUMERIC := 0;
  v_it       JSONB;
  v_item     public.order_items%ROWTYPE;
  v_qty      INTEGER;
  v_amount   NUMERIC;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Item refund wajib diisi' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments
  WHERE order_id = p_order;

  IF v_order.status <> 'paid'
     AND NOT (
       v_order.status IN ('confirmed', 'preparing', 'ready', 'served')
       AND v_paid >= v_order.total_amount - 0.01
     ) THEN
    RAISE EXCEPTION
      'Hanya order lunas yang bisa direfund sebagian'
      USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR v_order.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini'
      USING ERRCODE = '42501';
  END IF;

  v_approver := public._find_approver(
    v_order.outlet_id, p_approver_pin, p_approver_id
  );
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;

  v_method := COALESCE(
    (SELECT p.method FROM public.payments p
     WHERE p.order_id = p_order
     ORDER BY p.amount DESC LIMIT 1),
    'cash'
  );

  INSERT INTO public.refunds(
    order_id, outlet_id, amount, method, reason, refunded_by, approved_by
  ) VALUES (
    p_order, v_order.outlet_id, 0, v_method, p_reason, auth.uid(), v_approver
  ) RETURNING id INTO v_refund;

  -- Gabungkan item id duplikat agar satu payload tidak bisa melampaui quantity
  -- melalui dua entri terpisah.
  FOR v_it IN
    SELECT jsonb_build_object(
      'order_item_id', (x.value->>'order_item_id')::UUID,
      'qty', SUM((x.value->>'qty')::INTEGER)
    )
    FROM jsonb_array_elements(p_items) x(value)
    GROUP BY (x.value->>'order_item_id')::UUID
  LOOP
    v_qty := (v_it->>'qty')::INTEGER;
    SELECT * INTO v_item
    FROM public.order_items
    WHERE id = (v_it->>'order_item_id')::UUID
      AND order_id = p_order
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item tidak ada dalam order ini'
        USING ERRCODE = '22023';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0
       OR COALESCE(v_item.refunded_qty, 0) + v_qty > v_item.quantity THEN
      RAISE EXCEPTION 'Qty refund melebihi qty terjual'
        USING ERRCODE = '22023';
    END IF;

    v_amount := v_item.unit_price * v_qty;
    UPDATE public.order_items
    SET refunded_qty = COALESCE(refunded_qty, 0) + v_qty
    WHERE id = v_item.id;
    INSERT INTO public.refund_items(refund_id, order_item_id, qty, amount)
    VALUES (v_refund, v_item.id, v_qty, v_amount);
    v_total := v_total + v_amount;
  END LOOP;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Tidak ada item untuk direfund'
      USING ERRCODE = '22023';
  END IF;
  UPDATE public.refunds SET amount = v_total WHERE id = v_refund;

  RETURN jsonb_build_object(
    'refund_id', v_refund,
    'amount', v_total,
    'approver', (
      SELECT full_name FROM public.profiles WHERE id = v_approver
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  TO authenticated;

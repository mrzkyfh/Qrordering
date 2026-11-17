-- 220_refund_approver_permission.sql
--
-- `profiles.can_refund` adalah izin untuk MENYETUJUI refund. Kasir tetap boleh
-- meminta refund, tetapi PIN approver hanya sah ketika profil approver aktif,
-- memiliki role/outlet yang sesuai, dan can_refund=true pada saat RPC berjalan.

-- Tambahkan status izin ke data picker tanpa membuka pin_hash atau data rahasia.
-- DROP diperlukan karena PostgreSQL tidak dapat mengganti bentuk RETURNS TABLE
-- menggunakan CREATE OR REPLACE.
DROP FUNCTION public.list_clockin_staff(UUID);

CREATE FUNCTION public.list_clockin_staff(p_outlet UUID)
RETURNS TABLE(
  id UUID,
  full_name TEXT,
  role public.user_role,
  has_pin BOOLEAN,
  can_refund BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT target.id,
         target.full_name,
         target.role,
         (target.pin_hash IS NOT NULL) AS has_pin,
         COALESCE(target.can_refund, false) AS can_refund
  FROM public.profiles AS target
  JOIN public.profiles AS caller ON caller.id = auth.uid()
  WHERE caller.is_active
    AND caller.role IN ('owner', 'admin', 'manajer', 'kasir', 'pelanggan')
    AND (
      caller.role = 'owner'
      OR (caller.outlet_id = p_outlet AND caller.outlet_id IS NOT NULL)
    )
    AND target.is_active
    AND target.role <> 'pelanggan'
    AND (target.outlet_id = p_outlet OR target.role = 'owner')
  ORDER BY public.role_rank(target.role) DESC, target.full_name
$$;

REVOKE ALL ON FUNCTION public.list_clockin_staff(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_clockin_staff(UUID) TO authenticated;

-- Refund-only wrapper. Helper approval umum tetap utuh agar aturan void tidak
-- berubah. Row approver dikunci selama otorisasi agar revocation dan refund tidak
-- dapat saling melewati di tengah transaksi.
CREATE OR REPLACE FUNCTION public._find_refund_approver(
  p_outlet UUID,
  p_pin TEXT,
  p_approver_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_approver UUID;
BEGIN
  IF p_approver_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT profile.id
  INTO v_approver
  FROM public.profiles AS profile
  WHERE profile.id = p_approver_id
    AND profile.is_active
    AND COALESCE(profile.can_refund, false)
    AND public.role_rank(profile.role) >= 2
    AND (profile.role = 'owner' OR profile.outlet_id = p_outlet)
  FOR UPDATE;

  IF v_approver IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN public._find_approver(p_outlet, p_pin, p_approver_id);
END;
$$;

REVOKE ALL ON FUNCTION public._find_refund_approver(UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refund_order_with_approval(
  p_order UUID,
  p_reason TEXT,
  p_approver_pin TEXT,
  p_approver_id UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_approver_id UUID;
  v_name TEXT;
  v_order public.orders%ROWTYPE;
  v_existing_refund NUMERIC := 0;
  v_remaining NUMERIC := 0;
  v_payment RECORD;
  v_amount NUMERIC;
BEGIN
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_order.status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan refund';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR v_order.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini';
  END IF;

  SELECT public._find_refund_approver(
    v_order.outlet_id, p_approver_pin, p_approver_id
  ) INTO v_approver_id;
  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau approver tidak memiliki akses refund';
  END IF;
  SELECT full_name INTO v_name
  FROM public.profiles WHERE id = v_approver_id;

  SELECT COALESCE(SUM(amount), 0)
  INTO v_existing_refund
  FROM public.refunds
  WHERE order_id = p_order;
  v_remaining := GREATEST(v_order.total_amount - v_existing_refund, 0);

  FOR v_payment IN
    SELECT method, SUM(amount)::NUMERIC AS amount
    FROM public.payments
    WHERE order_id = p_order
    GROUP BY method
    ORDER BY method
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_amount := LEAST(v_payment.amount, v_remaining);
    IF v_amount > 0 THEN
      INSERT INTO public.refunds(
        order_id, outlet_id, amount, method, reason, refunded_by, approved_by
      ) VALUES (
        p_order, v_order.outlet_id, v_amount, v_payment.method,
        NULLIF(btrim(COALESCE(p_reason, '')), ''), auth.uid(), v_approver_id
      );
      v_remaining := v_remaining - v_amount;
    END IF;
  END LOOP;

  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders
  SET status = 'cancelled',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at = now()
  WHERE id = p_order;
  PERFORM public.restore_stock_for_order(p_order);

  RETURN QUERY SELECT v_name;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_with_approval(
  UUID, TEXT, TEXT, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_with_approval(
  UUID, TEXT, TEXT, UUID
) TO authenticated;

CREATE OR REPLACE FUNCTION public.refund_order_items(
  p_order UUID,
  p_items JSONB,
  p_reason TEXT,
  p_approver_pin TEXT,
  p_approver_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_approver UUID;
  v_refund UUID;
  v_method public.payment_method;
  v_paid NUMERIC := 0;
  v_total NUMERIC := 0;
  v_it JSONB;
  v_item public.order_items%ROWTYPE;
  v_qty INTEGER;
  v_amount NUMERIC;
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
    RAISE EXCEPTION 'Hanya order lunas yang bisa direfund sebagian'
      USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR v_order.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini'
      USING ERRCODE = '42501';
  END IF;

  v_approver := public._find_refund_approver(
    v_order.outlet_id, p_approver_pin, p_approver_id
  );
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau approver tidak memiliki akses refund'
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

COMMENT ON FUNCTION public._find_refund_approver(UUID, TEXT, UUID) IS
  'Internal-only refund approver validation; requires current can_refund=true.';

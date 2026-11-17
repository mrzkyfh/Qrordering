-- Catat refund penuh sebagai arus refund dan masukkan transaksi yang sudah
-- dibayar lalu dibatalkan ke rekonsiliasi dashboard.

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

  SELECT public._find_approver(
    v_order.outlet_id, p_approver_pin, p_approver_id
  ) INTO v_approver_id;
  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;
  SELECT full_name INTO v_name
  FROM public.profiles WHERE id = v_approver_id;

  SELECT COALESCE(SUM(amount), 0)
  INTO v_existing_refund
  FROM public.refunds
  WHERE order_id = p_order;
  v_remaining := GREATEST(v_order.total_amount - v_existing_refund, 0);

  -- Simpan refund menurut metode pembayaran agar arus kas dan tutup kasir
  -- dapat membedakan pengembalian tunai, kartu, dan QRIS.
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

-- Pulihkan refund penuh lama yang memiliki pembayaran tetapi belum memiliki
-- catatan refund. Tanggal refund mengikuti cancelled_at supaya audit konsisten.
INSERT INTO public.refunds(
  order_id, outlet_id, amount, method, reason,
  refunded_by, approved_by, created_at
)
SELECT
  o.id,
  o.outlet_id,
  LEAST(SUM(p.amount), o.total_amount)::NUMERIC,
  p.method,
  NULLIF(btrim(COALESCE(o.void_reason, '')), ''),
  o.cancelled_by,
  o.approved_by,
  COALESCE(o.cancelled_at, o.updated_at)
FROM public.orders o
JOIN public.payments p ON p.order_id = o.id
WHERE o.status = 'cancelled'
  AND NOT EXISTS (
    SELECT 1 FROM public.refunds r WHERE r.order_id = o.id
  )
GROUP BY
  o.id, o.outlet_id, o.total_amount, p.method, o.void_reason,
  o.cancelled_by, o.approved_by, o.cancelled_at, o.updated_at
HAVING LEAST(SUM(p.amount), o.total_amount) > 0;

CREATE OR REPLACE VIEW public.v_daily_sales AS
WITH live_orders AS (
  SELECT
    o.*,
    COALESCE(rf.refund, 0)::NUMERIC AS partial_refund,
    (o.status = 'cancelled' AND EXISTS (
      SELECT 1 FROM public.payments p WHERE p.order_id = o.id
    )) AS fully_refunded
  FROM public.orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount)::NUMERIC AS refund
    FROM public.refunds
    GROUP BY order_id
  ) rf ON rf.order_id = o.id
  WHERE o.status = 'paid'
     OR (
       o.status = 'cancelled'
       AND EXISTS (SELECT 1 FROM public.payments p WHERE p.order_id = o.id)
     )
)
SELECT
  o.outlet_id,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  COUNT(*)::INTEGER AS total_orders,
  COALESCE(SUM(o.subtotal), 0)::NUMERIC AS gross_revenue,
  COALESCE(SUM(o.discount_amount + COALESCE(o.loyalty_discount, 0)), 0)::NUMERIC AS total_discount,
  COALESCE(SUM(CASE WHEN o.fully_refunded THEN 0 ELSE o.tax_amount END), 0)::NUMERIC AS total_tax,
  COALESCE(SUM(CASE WHEN o.fully_refunded THEN 0 ELSE o.service_charge END), 0)::NUMERIC AS total_service_charge,
  COALESCE(SUM(
    CASE WHEN o.fully_refunded THEN 0
         ELSE GREATEST(o.total_amount - o.partial_refund, 0)
    END
  ), 0)::NUMERIC AS net_revenue,
  COALESCE(SUM(
    CASE WHEN o.fully_refunded THEN o.total_amount
         ELSE o.partial_refund
    END
  ), 0)::NUMERIC AS total_refund
FROM live_orders o
GROUP BY o.outlet_id, ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT
  s.outlet_id,
  s.sales_date::TEXT,
  s.order_count,
  s.gross,
  (
    s.discount + COALESCE((
      SELECT SUM(a.loyalty_discount)
      FROM public.transaction_archive_orders a
      WHERE a.outlet_id = s.outlet_id
        AND (a.created_at AT TIME ZONE 'Asia/Jakarta')::DATE = s.sales_date
        AND a.status = 'paid'
    ), 0)
  )::NUMERIC,
  s.tax,
  s.service,
  s.net,
  s.refund
FROM public.sales_daily_summary s
JOIN public.transaction_archive_manifest m
  ON m.outlet_id = s.outlet_id
 AND m.business_date = s.sales_date;

ALTER VIEW public.v_daily_sales SET (security_invoker = on);
GRANT SELECT ON public.v_daily_sales TO authenticated;

CREATE OR REPLACE FUNCTION public.report_profit_loss_range(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  gross_revenue NUMERIC,
  total_discount NUMERIC,
  total_refund NUMERIC,
  net_revenue NUMERIC,
  cost_of_goods NUMERIC,
  gross_profit NUMERIC,
  total_expenses NUMERIC,
  net_profit NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH revenue AS (
    SELECT
      COALESCE(SUM(v.gross_revenue), 0)::NUMERIC AS gross_revenue,
      COALESCE(SUM(v.total_discount), 0)::NUMERIC AS total_discount,
      COALESCE(SUM(v.total_refund), 0)::NUMERIC AS total_refund,
      COALESCE(SUM(
        GREATEST(v.net_revenue - v.total_tax - v.total_service_charge, 0)
      ), 0)::NUMERIC AS net_revenue
    FROM public.v_daily_sales v
    WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
      AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  ), live_hpp AS (
    SELECT COALESCE(SUM(h.hpp_total), 0)::NUMERIC AS amount
    FROM public.v_order_hpp h
    WHERE h.status = 'paid'
      AND (p_outlet_id IS NULL OR h.outlet_id = p_outlet_id)
      AND (h.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
        BETWEEN p_date_from AND p_date_to
  ), archived_hpp AS (
    SELECT COALESCE(SUM(s.cogs), 0)::NUMERIC AS amount
    FROM public.sales_daily_summary s
    JOIN public.transaction_archive_manifest m
      ON m.outlet_id = s.outlet_id
     AND m.business_date = s.sales_date
    WHERE (p_outlet_id IS NULL OR s.outlet_id = p_outlet_id)
      AND s.sales_date BETWEEN p_date_from AND p_date_to
  ), operating_expenses AS (
    SELECT COALESCE(SUM(e.amount), 0)::NUMERIC AS amount
    FROM public.expenses e
    WHERE (p_outlet_id IS NULL OR e.outlet_id = p_outlet_id)
      AND e.expense_date BETWEEN p_date_from AND p_date_to
      AND e.category <> 'bahan_baku'
  ), totals AS (
    SELECT
      r.gross_revenue,
      r.total_discount,
      r.total_refund,
      r.net_revenue,
      (lh.amount + ah.amount)::NUMERIC AS cost_of_goods,
      oe.amount::NUMERIC AS total_expenses
    FROM revenue r
    CROSS JOIN live_hpp lh
    CROSS JOIN archived_hpp ah
    CROSS JOIN operating_expenses oe
  )
  SELECT
    t.gross_revenue,
    t.total_discount,
    t.total_refund,
    t.net_revenue,
    t.cost_of_goods,
    (t.net_revenue - t.cost_of_goods)::NUMERIC,
    t.total_expenses,
    (t.net_revenue - t.cost_of_goods - t.total_expenses)::NUMERIC
  FROM totals t
  WHERE p_date_from IS NOT NULL
    AND p_date_to IS NOT NULL
    AND p_date_from <= p_date_to;
$$;

REVOKE ALL ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  TO authenticated;

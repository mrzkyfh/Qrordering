-- 221_department_financial_reconciliation.sql
--
-- Rekonsiliasi penerimaan pelanggan per departemen. Nilai finansial selalu
-- berasal dari snapshot orders; konfigurasi pajak outlet saat ini tidak dibaca.
-- RPC lama report_department_sales dipertahankan untuk kompatibilitas.

CREATE OR REPLACE FUNCTION public.report_department_financial_reconciliation(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  department_id UUID,
  department_name TEXT,
  color TEXT,
  total_orders BIGINT,
  qty_sold BIGINT,
  subtotal NUMERIC,
  discount_amount NUMERIC,
  tax_inclusive NUMERIC,
  tax_exclusive NUMERIC,
  service_charge NUMERIC,
  rounding_amount NUMERIC,
  refund_amount NUMERIC,
  unallocated_adjustment NUMERIC,
  net_receipts NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH live_orders AS (
    SELECT
      o.*,
      COALESCE((SELECT SUM(r.amount) FROM public.refunds r WHERE r.order_id = o.id), 0)::NUMERIC AS refund_total,
      (o.status = 'cancelled' AND EXISTS (
        SELECT 1 FROM public.payments p WHERE p.order_id = o.id
      )) AS fully_refunded
    FROM public.orders o
    WHERE o.outlet_id = p_outlet_id
      AND (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE BETWEEN p_date_from AND p_date_to
      AND (
        o.status = 'paid'
        OR (o.status = 'cancelled' AND EXISTS (
          SELECT 1 FROM public.payments p WHERE p.order_id = o.id
        ))
      )
  ), item_departments AS (
    SELECT
      o.id AS order_id,
      md.id AS department_id,
      COALESCE(md.name, 'Tanpa Departemen') AS department_name,
      md.color,
      SUM(oi.subtotal)::NUMERIC AS department_subtotal,
      SUM(GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0))::BIGINT AS qty_sold
    FROM live_orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
    LEFT JOIN public.menu_departments md ON md.id = mc.department_id
    GROUP BY o.id, md.id, COALESCE(md.name, 'Tanpa Departemen'), md.color
  ), weighted AS (
    SELECT
      d.*,
      o.subtotal AS order_subtotal,
      (o.discount_amount + COALESCE(o.loyalty_discount, 0))::NUMERIC AS order_discount,
      CASE WHEN COALESCE(o.tax_inclusive, false) THEN o.tax_amount ELSE 0 END::NUMERIC AS order_tax_inclusive,
      CASE WHEN COALESCE(o.tax_inclusive, false) THEN 0 ELSE o.tax_amount END::NUMERIC AS order_tax_exclusive,
      o.service_charge::NUMERIC AS order_service,
      (
        o.total_amount
        - (GREATEST(o.subtotal - o.discount_amount - COALESCE(o.loyalty_discount, 0), 0)
           + CASE WHEN COALESCE(o.tax_inclusive, false) THEN 0 ELSE o.tax_amount END
           + o.service_charge)
      )::NUMERIC AS order_rounding,
      CASE WHEN o.fully_refunded THEN o.total_amount ELSE o.refund_total END::NUMERIC AS order_refund,
      SUM(d.department_subtotal) OVER (PARTITION BY d.order_id)::NUMERIC AS weight_total,
      ROW_NUMBER() OVER (
        PARTITION BY d.order_id
        ORDER BY d.department_subtotal DESC, d.department_id NULLS LAST, d.department_name
      ) AS allocation_rank
    FROM item_departments d
    JOIN live_orders o ON o.id = d.order_id
  ), initially_allocated AS (
    SELECT
      w.*,
      ROUND(w.order_discount * w.department_subtotal / NULLIF(w.weight_total, 0), 0) AS discount_part,
      ROUND(w.order_tax_inclusive * w.department_subtotal / NULLIF(w.weight_total, 0), 0) AS tax_inclusive_part,
      ROUND(w.order_tax_exclusive * w.department_subtotal / NULLIF(w.weight_total, 0), 0) AS tax_exclusive_part,
      ROUND(w.order_service * w.department_subtotal / NULLIF(w.weight_total, 0), 0) AS service_part,
      ROUND(w.order_rounding * w.department_subtotal / NULLIF(w.weight_total, 0), 0) AS rounding_part
    FROM weighted w
  ), component_allocations AS (
    SELECT
      a.*,
      a.discount_part + CASE WHEN a.allocation_rank = 1 THEN
        a.order_discount - SUM(a.discount_part) OVER (PARTITION BY a.order_id) ELSE 0 END AS allocated_discount,
      a.tax_inclusive_part + CASE WHEN a.allocation_rank = 1 THEN
        a.order_tax_inclusive - SUM(a.tax_inclusive_part) OVER (PARTITION BY a.order_id) ELSE 0 END AS allocated_tax_inclusive,
      a.tax_exclusive_part + CASE WHEN a.allocation_rank = 1 THEN
        a.order_tax_exclusive - SUM(a.tax_exclusive_part) OVER (PARTITION BY a.order_id) ELSE 0 END AS allocated_tax_exclusive,
      a.service_part + CASE WHEN a.allocation_rank = 1 THEN
        a.order_service - SUM(a.service_part) OVER (PARTITION BY a.order_id) ELSE 0 END AS allocated_service,
      a.rounding_part + CASE WHEN a.allocation_rank = 1 THEN
        a.order_rounding - SUM(a.rounding_part) OVER (PARTITION BY a.order_id) ELSE 0 END AS allocated_rounding
    FROM initially_allocated a
  ), item_refunds AS (
    SELECT
      r.order_id,
      md.id AS department_id,
      COALESCE(md.name, 'Tanpa Departemen') AS department_name,
      SUM(ri.amount)::NUMERIC AS amount
    FROM public.refunds r
    JOIN public.refund_items ri ON ri.refund_id = r.id
    JOIN public.order_items oi ON oi.id = ri.order_item_id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
    LEFT JOIN public.menu_departments md ON md.id = mc.department_id
    JOIN live_orders o ON o.id = r.order_id AND NOT o.fully_refunded
    GROUP BY r.order_id, md.id, COALESCE(md.name, 'Tanpa Departemen')
  ), allocated_rows AS (
    SELECT
      c.department_id,
      c.department_name,
      c.color,
      COUNT(DISTINCT c.order_id)::BIGINT AS total_orders,
      SUM(c.qty_sold)::BIGINT AS qty_sold,
      SUM(c.department_subtotal)::NUMERIC AS subtotal,
      SUM(c.allocated_discount)::NUMERIC AS discount_amount,
      SUM(c.allocated_tax_inclusive)::NUMERIC AS tax_inclusive,
      SUM(c.allocated_tax_exclusive)::NUMERIC AS tax_exclusive,
      SUM(c.allocated_service)::NUMERIC AS service_charge,
      SUM(c.allocated_rounding)::NUMERIC AS rounding_amount,
      SUM(COALESCE(ir.amount, 0))::NUMERIC AS refund_amount,
      0::NUMERIC AS unallocated_adjustment,
      SUM(
        c.department_subtotal - c.allocated_discount
        + c.allocated_tax_exclusive + c.allocated_service + c.allocated_rounding
        - COALESCE(ir.amount, 0)
      )::NUMERIC AS net_receipts
    FROM component_allocations c
    LEFT JOIN item_refunds ir
      ON ir.order_id = c.order_id
     AND ir.department_id IS NOT DISTINCT FROM c.department_id
     AND ir.department_name = c.department_name
    GROUP BY c.department_id, c.department_name, c.color
  ), refund_residuals AS (
    SELECT
      SUM(
        o.order_refund - COALESCE((
          SELECT SUM(ir.amount) FROM item_refunds ir WHERE ir.order_id = o.order_id
        ), 0)
      )::NUMERIC AS amount
    FROM (SELECT DISTINCT order_id, order_refund FROM weighted) o
  ), orders_without_items AS (
    SELECT
      COALESCE(SUM(o.total_amount - CASE WHEN o.fully_refunded THEN o.total_amount ELSE o.refund_total END), 0)::NUMERIC AS receipts
    FROM live_orders o
    WHERE NOT EXISTS (SELECT 1 FROM item_departments d WHERE d.order_id = o.id)
  ), archived AS (
    SELECT
      COALESCE(SUM(s.gross), 0)::NUMERIC AS gross,
      COALESCE(SUM(s.discount + COALESCE((
        SELECT SUM(a.loyalty_discount)
        FROM public.transaction_archive_orders a
        WHERE a.outlet_id = s.outlet_id
          AND (a.created_at AT TIME ZONE 'Asia/Jakarta')::DATE = s.sales_date
          AND a.status = 'paid'
      ), 0)), 0)::NUMERIC AS discount,
      COALESCE(SUM(s.service), 0)::NUMERIC AS service,
      COALESCE(SUM(s.refund), 0)::NUMERIC AS refund,
      COALESCE(SUM(s.net), 0)::NUMERIC AS receipts
    FROM public.sales_daily_summary s
    JOIN public.transaction_archive_manifest m
      ON m.outlet_id = s.outlet_id AND m.business_date = s.sales_date
    WHERE s.outlet_id = p_outlet_id
      AND s.sales_date BETWEEN p_date_from AND p_date_to
  ), adjustment_row AS (
    SELECT
      NULL::UUID AS department_id,
      'Penyesuaian / Belum Terdistribusi'::TEXT AS department_name,
      '#64748B'::TEXT AS color,
      0::BIGINT AS total_orders,
      0::BIGINT AS qty_sold,
      a.gross::NUMERIC AS subtotal,
      a.discount::NUMERIC AS discount_amount,
      0::NUMERIC AS tax_inclusive,
      0::NUMERIC AS tax_exclusive,
      a.service::NUMERIC AS service_charge,
      0::NUMERIC AS rounding_amount,
      (a.refund + GREATEST(COALESCE(r.amount, 0), 0))::NUMERIC AS refund_amount,
      (
        a.receipts - (a.gross - a.discount + a.service - a.refund)
        + COALESCE(n.receipts, 0)
      )::NUMERIC AS unallocated_adjustment,
      (
        a.receipts + COALESCE(n.receipts, 0) - GREATEST(COALESCE(r.amount, 0), 0)
      )::NUMERIC AS net_receipts
    FROM archived a
    CROSS JOIN refund_residuals r
    CROSS JOIN orders_without_items n
    WHERE a.gross <> 0 OR a.discount <> 0 OR a.service <> 0 OR a.refund <> 0
       OR a.receipts <> 0 OR COALESCE(r.amount, 0) <> 0 OR COALESCE(n.receipts, 0) <> 0
  )
  SELECT * FROM allocated_rows
  UNION ALL
  SELECT * FROM adjustment_row
  ORDER BY net_receipts DESC, department_name;
$$;

REVOKE ALL ON FUNCTION public.report_department_financial_reconciliation(UUID, DATE, DATE)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_department_financial_reconciliation(UUID, DATE, DATE)
  TO authenticated;

COMMENT ON FUNCTION public.report_department_financial_reconciliation(UUID, DATE, DATE) IS
  'Alokasi komponen order tersimpan per departemen; refund tanpa breakdown dan arsip lama ditampilkan sebagai penyesuaian agar total sama dengan v_daily_sales.net_revenue.';

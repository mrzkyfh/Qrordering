-- 194_exclude_tax_service_from_profit.sql
--
-- Pisahkan dengan tegas:
--   * gross_revenue  = subtotal produk sebelum diskon
--   * net_revenue    = pendapatan produk setelah diskon/refund, TANPA pajak/service
--   * v_daily_sales.net_revenue = total penerimaan pelanggan, termasuk pajak/service
--
-- Pajak dan service charge tetap dilaporkan, tetapi tidak lagi menjadi dasar
-- laba kotor/laba bersih. Pendapatan bersih diturunkan dari penerimaan aktual
-- setelah refund, lalu pajak dan service dikeluarkan. Rumus ini konsisten untuk
-- pajak exclusive maupun inclusive.

-- Lengkapi sumber harian dengan refund eksplisit. Rumus balik dari total
-- tagihan tidak aman untuk outlet dengan pajak inclusive, karena tax_amount
-- bersifat informasional dan memang tidak ditambahkan ke total_amount.
CREATE OR REPLACE VIEW public.v_daily_sales AS
SELECT
  o.outlet_id,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  COUNT(*)::INTEGER AS total_orders,
  COALESCE(SUM(o.subtotal), 0)::NUMERIC AS gross_revenue,
  COALESCE(SUM(o.discount_amount + COALESCE(o.loyalty_discount, 0)), 0)::NUMERIC AS total_discount,
  COALESCE(SUM(o.tax_amount), 0)::NUMERIC AS total_tax,
  COALESCE(SUM(o.service_charge), 0)::NUMERIC AS total_service_charge,
  COALESCE(SUM(o.total_amount - COALESCE(rf.refund, 0)), 0)::NUMERIC AS net_revenue,
  COALESCE(SUM(COALESCE(rf.refund, 0)), 0)::NUMERIC AS total_refund
FROM public.orders o
LEFT JOIN (
  SELECT order_id, SUM(amount)::NUMERIC AS refund
  FROM public.refunds
  GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid'
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
  )::NUMERIC AS total_discount,
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

COMMENT ON COLUMN public.v_daily_sales.net_revenue IS
  'Total penerimaan pelanggan setelah refund, termasuk pajak dan service charge. Nama kolom dipertahankan untuk kompatibilitas API lama.';
COMMENT ON COLUMN public.v_daily_sales.total_refund IS
  'Nominal refund tercatat yang sudah dikurangi dari net_revenue.';

CREATE OR REPLACE VIEW public.v_tax_report AS
SELECT
  outlet_id,
  sale_date,
  total_orders,
  gross_revenue,
  total_discount,
  total_tax,
  total_service_charge,
  net_revenue,
  total_refund
FROM public.v_daily_sales;

ALTER VIEW public.v_tax_report SET (security_invoker = on);
GRANT SELECT ON public.v_tax_report TO authenticated;

CREATE OR REPLACE VIEW public.v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    v.outlet_id,
    LEFT(v.sale_date, 7) AS month,
    SUM(v.gross_revenue)::NUMERIC AS gross_revenue,
    SUM(v.total_discount)::NUMERIC AS total_discount,
    SUM(v.total_refund)::NUMERIC AS total_refund,
    (
      SUM(v.net_revenue)
        - SUM(v.total_tax)
        - SUM(v.total_service_charge)
    )::NUMERIC AS net_revenue
  FROM public.v_daily_sales v
  GROUP BY v.outlet_id, LEFT(v.sale_date, 7)
), monthly_live_hpp AS (
  SELECT
    h.outlet_id,
    to_char(h.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(h.hpp_total)::NUMERIC AS cost_of_goods
  FROM public.v_order_hpp h
  WHERE h.status = 'paid'
  GROUP BY h.outlet_id, to_char(h.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
), monthly_archive_hpp AS (
  SELECT
    s.outlet_id,
    to_char(s.sales_date, 'YYYY-MM') AS month,
    SUM(s.cogs)::NUMERIC AS cost_of_goods
  FROM public.sales_daily_summary s
  JOIN public.transaction_archive_manifest m
    ON m.outlet_id = s.outlet_id
   AND m.business_date = s.sales_date
  GROUP BY s.outlet_id, to_char(s.sales_date, 'YYYY-MM')
), monthly_hpp AS (
  SELECT outlet_id, month, SUM(cost_of_goods)::NUMERIC AS cost_of_goods
  FROM (
    SELECT * FROM monthly_live_hpp
    UNION ALL
    SELECT * FROM monthly_archive_hpp
  ) h
  GROUP BY outlet_id, month
), monthly_expenses AS (
  SELECT
    e.outlet_id,
    to_char(e.expense_date::TIMESTAMPTZ, 'YYYY-MM') AS month,
    COALESCE(SUM(e.amount) FILTER (WHERE e.category <> 'bahan_baku'), 0)::NUMERIC AS total_expenses
  FROM public.expenses e
  GROUP BY e.outlet_id, to_char(e.expense_date::TIMESTAMPTZ, 'YYYY-MM')
), all_periods AS (
  SELECT outlet_id, month FROM monthly_revenue
  UNION SELECT outlet_id, month FROM monthly_hpp
  UNION SELECT outlet_id, month FROM monthly_expenses
)
SELECT
  p.outlet_id,
  p.month,
  COALESCE(r.gross_revenue, 0)::NUMERIC AS gross_revenue,
  COALESCE(r.total_discount, 0)::NUMERIC AS total_discount,
  COALESCE(r.total_refund, 0)::NUMERIC AS total_refund,
  COALESCE(r.net_revenue, 0)::NUMERIC AS net_revenue,
  COALESCE(h.cost_of_goods, 0)::NUMERIC AS cost_of_goods,
  (COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0))::NUMERIC AS gross_profit,
  COALESCE(e.total_expenses, 0)::NUMERIC AS total_expenses,
  (
    COALESCE(r.net_revenue, 0)
      - COALESCE(h.cost_of_goods, 0)
      - COALESCE(e.total_expenses, 0)
  )::NUMERIC AS net_profit
FROM all_periods p
LEFT JOIN monthly_revenue r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_hpp h ON h.outlet_id = p.outlet_id AND h.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;

ALTER VIEW public.v_profit_loss SET (security_invoker = on);
GRANT SELECT ON public.v_profit_loss TO authenticated;

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
      COALESCE(SUM(v.net_revenue), 0)::NUMERIC AS total_receipts,
      COALESCE(SUM(v.total_tax), 0)::NUMERIC AS total_tax,
      COALESCE(SUM(v.total_service_charge), 0)::NUMERIC AS total_service_charge
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
      (r.total_receipts - r.total_tax - r.total_service_charge)::NUMERIC AS net_revenue,
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
    (t.net_revenue - t.cost_of_goods)::NUMERIC AS gross_profit,
    t.total_expenses,
    (t.net_revenue - t.cost_of_goods - t.total_expenses)::NUMERIC AS net_profit
  FROM totals t
  WHERE p_date_from IS NOT NULL
    AND p_date_to IS NOT NULL
    AND p_date_from <= p_date_to;
$$;

REVOKE ALL ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  TO authenticated;

COMMENT ON VIEW public.v_profit_loss IS
  'Laba rugi berbasis pendapatan produk setelah diskon/refund; pajak dan service charge tidak dihitung sebagai laba.';
COMMENT ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE) IS
  'Laba rugi rentang tanggal; net_revenue tidak mencakup pajak dan service charge.';

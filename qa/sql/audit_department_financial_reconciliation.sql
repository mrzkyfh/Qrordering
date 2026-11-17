-- Read-only staging/production verification for migration 221.
-- Replace the three parameters in params before running.
WITH params AS (
  SELECT
    '<OUTLET_ID>'::UUID AS outlet_id,
    '<YYYY-MM-DD>'::DATE AS date_from,
    '<YYYY-MM-DD>'::DATE AS date_to
), department_total AS (
  SELECT COALESCE(SUM(r.net_receipts), 0)::NUMERIC AS amount
  FROM params p
  CROSS JOIN LATERAL public.report_department_financial_reconciliation(
    p.outlet_id, p.date_from, p.date_to
  ) r
), dashboard_total AS (
  SELECT COALESCE(SUM(v.net_revenue), 0)::NUMERIC AS amount
  FROM public.v_daily_sales v
  CROSS JOIN params p
  WHERE v.outlet_id = p.outlet_id
    AND v.sale_date::DATE BETWEEN p.date_from AND p.date_to
)
SELECT
  d.amount AS department_net_receipts,
  b.amount AS dashboard_customer_receipts,
  d.amount - b.amount AS difference,
  (d.amount = b.amount) AS reconciled
FROM department_total d
CROSS JOIN dashboard_total b;

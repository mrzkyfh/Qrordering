-- ============================================================
-- 011_peak_hours_view.sql
-- View analitik jam ramai (peak hours) per outlet per hari
-- FR-REPORT-07 | BRD BR-15
-- ============================================================

CREATE OR REPLACE VIEW v_peak_hours AS
SELECT
  o.outlet_id,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta')          AS sale_date,
  EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::integer AS hour_of_day,
  COUNT(*)::integer                                        AS total_orders,
  SUM(o.total_amount)::numeric                             AS total_revenue
FROM orders o
WHERE o.status = 'paid'
GROUP BY
  o.outlet_id,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta'),
  EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta');

GRANT SELECT ON v_peak_hours TO authenticated;

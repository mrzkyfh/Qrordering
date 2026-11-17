-- ============================================================
-- 013_stock_daily_view.sql
-- View laporan pergerakan stok harian per bahan baku
-- FR-REPORT-08 | Admin Panel scope
-- ============================================================

CREATE OR REPLACE VIEW v_stock_daily AS
SELECT
  st.outlet_id,
  st.ingredient_id,
  i.name                                                               AS ingredient_name,
  i.unit,
  i.min_stock_qty,
  DATE(st.created_at AT TIME ZONE 'Asia/Jakarta')                     AS txn_date,
  SUM(CASE
    WHEN st.type IN ('purchase', 'return') THEN st.qty
    WHEN st.type = 'adjustment' AND st.qty_after > st.qty_before THEN st.qty
    ELSE 0
  END)::numeric AS total_in,
  SUM(CASE
    WHEN st.type IN ('usage', 'waste') THEN st.qty
    WHEN st.type = 'adjustment' AND st.qty_after < st.qty_before THEN st.qty
    ELSE 0
  END)::numeric AS total_out,
  SUM(st.qty_after - st.qty_before)::numeric                          AS net_change
FROM stock_transactions st
JOIN ingredients i ON i.id = st.ingredient_id
GROUP BY
  st.outlet_id,
  st.ingredient_id,
  i.name,
  i.unit,
  i.min_stock_qty,
  DATE(st.created_at AT TIME ZONE 'Asia/Jakarta');

GRANT SELECT ON v_stock_daily TO authenticated;

COMMENT ON VIEW v_stock_daily IS 'Ringkasan pergerakan stok per bahan per hari. Saldo awal/akhir dihitung di aplikasi.';

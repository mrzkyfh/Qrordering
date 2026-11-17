-- ============================================================
-- 044_shift_summary_view.sql
-- View agregasi total kas yang masuk per shift, dipisah tunai vs non-tunai.
-- Dipakai oleh halaman "Laporan Tutup Kasir" di owner panel.
-- ============================================================

DROP VIEW IF EXISTS v_shift_summary;

CREATE VIEW v_shift_summary AS
SELECT
  s.id AS shift_id,
  s.outlet_id,
  COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'cash'),  0)::NUMERIC(14,2) AS cash_received,
  COALESCE(SUM(p.amount) FILTER (WHERE p.method <> 'cash'), 0)::NUMERIC(14,2) AS non_cash_received,
  COUNT(DISTINCT o.id) FILTER (WHERE o.status = 'paid')::INTEGER             AS paid_orders
FROM shifts s
LEFT JOIN orders   o ON o.shift_id = s.id
LEFT JOIN payments p ON p.order_id = o.id AND o.status = 'paid'
GROUP BY s.id, s.outlet_id;

GRANT SELECT ON v_shift_summary TO authenticated;

COMMENT ON VIEW v_shift_summary IS
  'Total payment per shift: cash_received (tunai aktual), non_cash_received '
  '(qris/debit/credit/ewallet/transfer), paid_orders (jumlah order paid).';
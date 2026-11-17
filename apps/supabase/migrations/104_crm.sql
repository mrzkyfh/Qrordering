-- 104_crm.sql
-- FITUR ROADMAP-5 — CRM Pelanggan.
--
-- Reuse loyalty_members (jangan buat tabel pelanggan baru). Tambah data CRM
-- (alamat, ultah, catatan) + view ringkasan (total belanja, jml kunjungan,
-- kunjungan terakhir) untuk halaman pelanggan.

ALTER TABLE loyalty_members
  ADD COLUMN IF NOT EXISTS address  TEXT,
  ADD COLUMN IF NOT EXISTS birthday DATE,
  ADD COLUMN IF NOT EXISTS note     TEXT;

-- Ringkasan per pelanggan (net refund, hanya order paid).
DROP VIEW IF EXISTS v_customer_summary;
CREATE VIEW v_customer_summary AS
SELECT
  m.id          AS member_id,
  m.outlet_id,
  m.name,
  m.phone,
  m.tier,
  m.points,
  COUNT(o.id)                                                        AS total_orders,
  COALESCE(SUM(o.total_amount - COALESCE(rf.refund, 0)), 0)::numeric AS total_spent,
  MAX(o.created_at)                                                  AS last_order_at
FROM loyalty_members m
LEFT JOIN orders o
       ON o.loyalty_member_id = m.id AND o.status = 'paid'
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM refunds GROUP BY order_id
) rf ON rf.order_id = o.id
GROUP BY m.id, m.outlet_id, m.name, m.phone, m.tier, m.points;

GRANT SELECT ON v_customer_summary TO authenticated;
ALTER VIEW v_customer_summary SET (security_invoker = on);

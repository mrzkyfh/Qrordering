-- 095_partial_refund_reporting.sql
-- FITUR NEW-2 (Fase 2) — laporan penjualan dikurangi refund sebagian.
--
-- Fase 1 (094) mencatat refund tapi laporan masih gross. Migrasi ini membuat
-- semua view penjualan yang dikonsumsi jadi NET (dikurangi refund).
-- Semua LEFT JOIN/COALESCE → order TANPA refund tidak berubah angkanya.
--
-- CATATAN: view di-DROP + CREATE ulang (bukan CREATE OR REPLACE) agar tidak
-- terganjal batasan "cannot change column type / drop column" — skema terdeploy
-- bisa berbeda dari file. Tidak ada view lain yang bergantung pada view ini
-- (sudah dicek), jadi DROP aman. GRANT + security_invoker di-set ulang.
--
-- ⚠️ WAJIB verifikasi di staging (SQL tak bisa diuji lokal).

-- ── 0. Tambah metode ke refunds (agar bisa net per metode) ──────────────────
ALTER TABLE refunds
  ADD COLUMN IF NOT EXISTS method payment_method NOT NULL DEFAULT 'cash';

CREATE OR REPLACE FUNCTION refund_order_items(
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
  v_outlet   UUID;
  v_status   order_status;
  v_approver UUID;
  v_refund   UUID;
  v_method   payment_method;
  v_total    NUMERIC := 0;
  v_it       JSONB;
  v_item     order_items%ROWTYPE;
  v_qty      INTEGER;
  v_amount   NUMERIC;
BEGIN
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status <> 'paid' THEN
    RAISE EXCEPTION 'Hanya order lunas yang bisa direfund sebagian';
  END IF;
  IF NOT (is_owner() OR v_outlet = auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini';
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin, p_approver_id);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  v_method := COALESCE(
    (SELECT p.method FROM payments p WHERE p.order_id = p_order
     ORDER BY p.amount DESC LIMIT 1),
    'cash');

  INSERT INTO refunds (order_id, outlet_id, amount, method, reason, refunded_by, approved_by)
  VALUES (p_order, v_outlet, 0, v_method, p_reason, auth.uid(), v_approver)
  RETURNING id INTO v_refund;

  FOR v_it IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_it->>'qty')::INTEGER;
    SELECT * INTO v_item FROM order_items
    WHERE id = (v_it->>'order_item_id')::UUID AND order_id = p_order;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ada dalam order ini'; END IF;
    IF v_qty <= 0 OR v_item.refunded_qty + v_qty > v_item.quantity THEN
      RAISE EXCEPTION 'Qty refund melebihi qty terjual';
    END IF;

    v_amount := v_item.unit_price * v_qty;
    UPDATE order_items SET refunded_qty = refunded_qty + v_qty WHERE id = v_item.id;
    INSERT INTO refund_items (refund_id, order_item_id, qty, amount)
    VALUES (v_refund, v_item.id, v_qty, v_amount);
    v_total := v_total + v_amount;
  END LOOP;

  IF v_total <= 0 THEN RAISE EXCEPTION 'Tidak ada item untuk direfund'; END IF;
  UPDATE refunds SET amount = v_total WHERE id = v_refund;

  RETURN jsonb_build_object(
    'refund_id', v_refund, 'amount', v_total,
    'approver', (SELECT full_name FROM profiles WHERE id = v_approver));
END;
$$;

-- ── Helper: refund per order (dipakai berulang di view) ──────────────────────
-- (inline subquery di tiap view; tidak dibuat view terpisah agar mandiri)

-- ── 1. v_category_sales ─────────────────────────────────────────────────────
DROP VIEW IF EXISTS v_category_sales;
CREATE VIEW v_category_sales AS
SELECT
  mi.outlet_id,
  mc.id                                                   AS category_id,
  mc.name                                                 AS category_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text  AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::integer             AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price)::numeric AS total_revenue,
  COUNT(DISTINCT o.id)::integer                           AS total_orders
FROM order_items oi
JOIN menu_items      mi ON mi.id  = oi.menu_item_id
JOIN orders          o  ON o.id   = oi.order_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY mi.outlet_id, mc.id, mc.name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_category_sales TO authenticated;

-- ── 2. v_department_sales ───────────────────────────────────────────────────
DROP VIEW IF EXISTS v_department_sales;
CREATE VIEW v_department_sales AS
SELECT
  COALESCE(md.outlet_id, mi.outlet_id)               AS outlet_id,
  md.id                                               AS department_id,
  COALESCE(md.name, 'Tanpa Departemen')               AS department_name,
  md.color,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text AS sale_date,
  COUNT(DISTINCT o.id)::integer                       AS total_orders,
  SUM(oi.quantity - oi.refunded_qty)::integer         AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price)::numeric AS total_revenue
FROM order_items oi
JOIN menu_items      mi ON mi.id  = oi.menu_item_id
JOIN orders          o  ON o.id   = oi.order_id
LEFT JOIN menu_categories   mc ON mc.id = mi.category_id
LEFT JOIN menu_departments  md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY COALESCE(md.outlet_id, mi.outlet_id), md.id,
  COALESCE(md.name, 'Tanpa Departemen'), md.color,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_department_sales TO authenticated;

-- ── 3. v_menu_sales ─────────────────────────────────────────────────────────
DROP VIEW IF EXISTS v_menu_sales;
CREATE VIEW v_menu_sales AS
SELECT
  mi.outlet_id,
  mi.id                                               AS menu_item_id,
  mi.name                                             AS menu_name,
  mi.price,
  mc.name                                             AS category_name,
  md.name                                             AS department_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::integer         AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price)::numeric AS total_revenue,
  COUNT(DISTINCT o.id)::integer                       AS order_count
FROM order_items oi
JOIN menu_items        mi ON mi.id  = oi.menu_item_id
JOIN orders            o  ON o.id   = oi.order_id
LEFT JOIN menu_categories   mc ON mc.id = mi.category_id
LEFT JOIN menu_departments  md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY mi.outlet_id, mi.id, mi.name, mi.price, mc.name, md.name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_menu_sales TO authenticated;

-- ── 4. v_tax_report (net_revenue dikurangi refund + total_refund) ───────────
DROP VIEW IF EXISTS v_tax_report;
CREATE VIEW v_tax_report AS
SELECT
  o.outlet_id,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text AS sale_date,
  COUNT(*)::integer                                    AS total_orders,
  SUM(o.subtotal)::numeric                             AS gross_revenue,
  SUM(o.discount_amount)::numeric                      AS total_discount,
  SUM(o.tax_amount)::numeric                           AS total_tax,
  SUM(o.service_charge)::numeric                       AS total_service_charge,
  SUM(o.total_amount - COALESCE(rf.refund, 0))::numeric AS net_revenue,
  COALESCE(SUM(rf.refund), 0)::numeric                 AS total_refund
FROM orders o
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM refunds GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid'
GROUP BY o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_tax_report TO authenticated;

-- ── 5. v_payment_summary (refund = baris negatif per metode) ────────────────
DROP VIEW IF EXISTS v_payment_summary;
CREATE VIEW v_payment_summary AS
SELECT outlet_id, pay_date, method,
  SUM(txn)::bigint    AS total_transactions,
  SUM(amt)::numeric   AS total_amount
FROM (
  SELECT p.outlet_id,
         DATE(p.paid_at AT TIME ZONE 'Asia/Jakarta') AS pay_date,
         p.method, 1 AS txn, p.amount AS amt
  FROM payments p
  UNION ALL
  SELECT r.outlet_id,
         DATE(r.created_at AT TIME ZONE 'Asia/Jakarta') AS pay_date,
         r.method, 0 AS txn, -r.amount AS amt
  FROM refunds r
) x
GROUP BY outlet_id, pay_date, method;
GRANT SELECT ON v_payment_summary TO authenticated;

-- ── 6. v_shift_summary (kas & non-kas dikurangi refund per shift) ───────────
DROP VIEW IF EXISTS v_shift_summary;
CREATE VIEW v_shift_summary AS
SELECT
  s.id AS shift_id,
  s.outlet_id,
  (COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'cash'), 0)
   - COALESCE((SELECT SUM(r.amount) FROM refunds r JOIN orders o2 ON o2.id = r.order_id
               WHERE o2.shift_id = s.id AND r.method = 'cash'), 0))::NUMERIC(14,2) AS cash_received,
  (COALESCE(SUM(p.amount) FILTER (WHERE p.method <> 'cash'), 0)
   - COALESCE((SELECT SUM(r.amount) FROM refunds r JOIN orders o2 ON o2.id = r.order_id
               WHERE o2.shift_id = s.id AND r.method <> 'cash'), 0))::NUMERIC(14,2) AS non_cash_received,
  COUNT(DISTINCT o.id) FILTER (WHERE o.status = 'paid')::INTEGER AS paid_orders
FROM shifts s
LEFT JOIN orders   o ON o.shift_id = s.id
LEFT JOIN payments p ON p.order_id = o.id AND o.status = 'paid'
GROUP BY s.id, s.outlet_id;
GRANT SELECT ON v_shift_summary TO authenticated;

-- ── 7. v_daily_sales (net_revenue dikurangi refund per order) ───────────────
DROP VIEW IF EXISTS v_daily_sales;
CREATE VIEW v_daily_sales AS
SELECT
  o.outlet_id,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text          AS sale_date,
  COUNT(*)::integer                                               AS total_orders,
  COALESCE(SUM(o.subtotal), 0)::numeric                           AS gross_revenue,
  COALESCE(SUM(o.discount_amount), 0)::numeric                    AS total_discount,
  COALESCE(SUM(o.tax_amount), 0)::numeric                         AS total_tax,
  COALESCE(SUM(o.service_charge), 0)::numeric                     AS total_service_charge,
  COALESCE(SUM(o.total_amount - COALESCE(rf.refund, 0)), 0)::numeric AS net_revenue
FROM orders o
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM refunds GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid'
GROUP BY o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_daily_sales TO authenticated;

-- ── 8. v_top_menu_items (NET pakai refunded_qty) ────────────────────────────
DROP VIEW IF EXISTS v_top_menu_items;
CREATE VIEW v_top_menu_items AS
SELECT
  oi.menu_item_id,
  mi.outlet_id,
  mi.name                                                 AS menu_item_name,
  mc.name                                                 AS category_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text  AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::integer             AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price)::numeric AS total_revenue
FROM order_items oi
JOIN menu_items mi  ON mi.id = oi.menu_item_id
JOIN orders o       ON o.id  = oi.order_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY oi.menu_item_id, mi.outlet_id, mi.name, mc.name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;
GRANT SELECT ON v_top_menu_items TO authenticated;

-- ── 9. v_kasir_performance (revenue NET per kasir) ──────────────────────────
DROP VIEW IF EXISTS v_kasir_performance;
CREATE VIEW v_kasir_performance AS
SELECT
  o.outlet_id,
  o.created_by             AS kasir_id,
  p.full_name              AS kasir_name,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta') AS work_date,
  COUNT(*)                 AS total_orders,
  SUM(o.total_amount - COALESCE(rf.refund, 0))   AS total_revenue,
  AVG(o.total_amount - COALESCE(rf.refund, 0))   AS avg_order_value,
  SUM(o.discount_amount)   AS total_discount_given
FROM orders o
JOIN profiles p ON p.id = o.created_by
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM refunds GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid' AND o.created_by IS NOT NULL
GROUP BY o.outlet_id, o.created_by, p.full_name,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta');
GRANT SELECT ON v_kasir_performance TO authenticated;

-- ── 10. v_profit_loss (total_refund nyata + net_revenue net) ────────────────
DROP VIEW IF EXISTS v_profit_loss;
CREATE VIEW v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    o.outlet_id,
    TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(o.subtotal) AS gross_revenue,
    SUM(o.discount_amount) AS total_discount,
    COALESCE(SUM(rf.refund), 0) AS total_refund,
    SUM(o.total_amount - COALESCE(rf.refund, 0)) AS net_revenue
  FROM orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund FROM refunds GROUP BY order_id
  ) rf ON rf.order_id = o.id
  WHERE o.status = 'paid'
  GROUP BY o.outlet_id, TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
),
monthly_expenses AS (
  SELECT
    outlet_id,
    TO_CHAR(expense_date, 'YYYY-MM') AS month,
    COALESCE(SUM(amount) FILTER (WHERE category = 'bahan_baku'), 0) AS cost_of_goods,
    COALESCE(SUM(amount) FILTER (WHERE category != 'bahan_baku'), 0) AS total_expenses
  FROM expenses
  GROUP BY outlet_id, TO_CHAR(expense_date, 'YYYY-MM')
),
all_periods AS (
  SELECT DISTINCT outlet_id, month FROM monthly_revenue
  UNION
  SELECT DISTINCT outlet_id, month FROM monthly_expenses
)
SELECT
  p.outlet_id,
  p.month,
  COALESCE(r.gross_revenue, 0)::numeric AS gross_revenue,
  COALESCE(r.total_discount, 0)::numeric AS total_discount,
  COALESCE(r.total_refund, 0)::numeric AS total_refund,
  COALESCE(r.net_revenue, 0)::numeric AS net_revenue,
  COALESCE(e.cost_of_goods, 0)::numeric AS cost_of_goods,
  (COALESCE(r.net_revenue, 0) - COALESCE(e.cost_of_goods, 0))::numeric AS gross_profit,
  COALESCE(e.total_expenses, 0)::numeric AS total_expenses,
  ((COALESCE(r.net_revenue, 0) - COALESCE(e.cost_of_goods, 0)) - COALESCE(e.total_expenses, 0))::numeric AS net_profit
FROM all_periods p
LEFT JOIN monthly_revenue  r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;
GRANT SELECT ON v_profit_loss TO authenticated;

-- ── 11. Re-assert security_invoker (tetap dieksekusi dgn hak pemanggil) ─────
ALTER VIEW v_category_sales    SET (security_invoker = on);
ALTER VIEW v_department_sales  SET (security_invoker = on);
ALTER VIEW v_menu_sales        SET (security_invoker = on);
ALTER VIEW v_tax_report        SET (security_invoker = on);
ALTER VIEW v_payment_summary   SET (security_invoker = on);
ALTER VIEW v_shift_summary     SET (security_invoker = on);
ALTER VIEW v_daily_sales       SET (security_invoker = on);
ALTER VIEW v_top_menu_items    SET (security_invoker = on);
ALTER VIEW v_kasir_performance SET (security_invoker = on);
ALTER VIEW v_profit_loss       SET (security_invoker = on);

-- ============================================================
-- 003_views.sql
-- Analytical views untuk dashboard dan laporan
-- ============================================================

-- ── v_daily_sales ────────────────────────────────────────────
-- Aggregasi penjualan per hari per outlet
CREATE OR REPLACE VIEW v_daily_sales AS
SELECT
  o.outlet_id,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta') AS sale_date,
  COUNT(*)                                        AS total_orders,
  SUM(o.subtotal)                                 AS gross_revenue,
  SUM(o.discount_amount)                          AS total_discount,
  SUM(o.tax_amount)                               AS total_tax,
  SUM(o.service_charge)                           AS total_service_charge,
  SUM(o.total_amount)                             AS net_revenue
FROM orders o
WHERE o.status IN ('paid')
GROUP BY o.outlet_id, DATE(o.created_at AT TIME ZONE 'Asia/Jakarta');

-- ── v_top_menu_items ─────────────────────────────────────────
-- Item menu terlaris (30 hari terakhir, bisa di-filter via WHERE di aplikasi)
CREATE OR REPLACE VIEW v_top_menu_items AS
SELECT
  oi.menu_item_id,
  mi.outlet_id,
  mi.name,
  mi.price,
  mi.image_url,
  mc.name                         AS category_name,
  SUM(oi.quantity)                AS total_qty,
  SUM(oi.subtotal)                AS total_revenue,
  COUNT(DISTINCT oi.order_id)     AS order_count
FROM order_items oi
JOIN menu_items mi  ON mi.id = oi.menu_item_id
JOIN orders o       ON o.id  = oi.order_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY oi.menu_item_id, mi.outlet_id, mi.name, mi.price, mi.image_url, mc.name;

-- ── v_payment_summary ────────────────────────────────────────
-- Ringkasan per metode pembayaran per hari per outlet
CREATE OR REPLACE VIEW v_payment_summary AS
SELECT
  p.outlet_id,
  DATE(p.paid_at AT TIME ZONE 'Asia/Jakarta') AS pay_date,
  p.method,
  COUNT(*)          AS total_transactions,
  SUM(p.amount)     AS total_amount
FROM payments p
GROUP BY p.outlet_id, DATE(p.paid_at AT TIME ZONE 'Asia/Jakarta'), p.method;

-- ── v_low_stock ──────────────────────────────────────────────
-- Bahan baku yang stok-nya di bawah atau mendekati minimum
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
  i.id            AS ingredient_id,
  i.outlet_id,
  i.name,
  i.unit,
  i.stock_qty,
  i.min_stock_qty,
  i.cost_per_unit,
  CASE
    WHEN i.stock_qty = 0             THEN 'out_of_stock'
    WHEN i.stock_qty <= i.min_stock_qty THEN 'critical'
    WHEN i.stock_qty <= i.min_stock_qty * 1.5 THEN 'low'
    ELSE 'ok'
  END AS status
FROM ingredients i
WHERE i.is_active = TRUE
  AND i.stock_qty <= i.min_stock_qty * 1.5;

-- ── v_profit_loss ────────────────────────────────────────────
-- Laporan laba rugi sederhana per bulan per outlet
CREATE OR REPLACE VIEW v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    outlet_id,
    DATE_TRUNC('month', created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS month,
    SUM(total_amount) AS revenue
  FROM orders
  WHERE status = 'paid'
  GROUP BY outlet_id, DATE_TRUNC('month', created_at AT TIME ZONE 'Asia/Jakarta')::DATE
),
monthly_expenses AS (
  SELECT
    outlet_id,
    DATE_TRUNC('month', expense_date::TIMESTAMPTZ AT TIME ZONE 'Asia/Jakarta')::DATE AS month,
    SUM(amount) AS total_expenses
  FROM expenses
  GROUP BY outlet_id, DATE_TRUNC('month', expense_date::TIMESTAMPTZ AT TIME ZONE 'Asia/Jakarta')::DATE
)
SELECT
  r.outlet_id,
  r.month,
  r.revenue,
  COALESCE(e.total_expenses, 0) AS total_expenses,
  r.revenue - COALESCE(e.total_expenses, 0) AS net_profit
FROM monthly_revenue r
LEFT JOIN monthly_expenses e
  ON e.outlet_id = r.outlet_id AND e.month = r.month;

-- ── v_kasir_performance ──────────────────────────────────────
-- Performa kasir: total transaksi, omzet, rata-rata per order
CREATE OR REPLACE VIEW v_kasir_performance AS
SELECT
  o.outlet_id,
  o.created_by             AS kasir_id,
  p.full_name              AS kasir_name,
  DATE(o.created_at AT TIME ZONE 'Asia/Jakarta') AS work_date,
  COUNT(*)                 AS total_orders,
  SUM(o.total_amount)      AS total_revenue,
  AVG(o.total_amount)      AS avg_order_value,
  SUM(o.discount_amount)   AS total_discount_given
FROM orders o
JOIN profiles p ON p.id = o.created_by
WHERE o.status = 'paid'
  AND o.created_by IS NOT NULL
GROUP BY o.outlet_id, o.created_by, p.full_name, DATE(o.created_at AT TIME ZONE 'Asia/Jakarta');

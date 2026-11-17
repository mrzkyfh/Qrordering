-- ============================================================
-- 007_fix_views.sql
-- Perbaikan semua views agar sesuai dengan TypeScript types
-- ============================================================

-- ── Drop existing views ──────────────────────────────────────
DROP VIEW IF EXISTS v_top_menu_items;
DROP VIEW IF EXISTS v_profit_loss;
DROP VIEW IF EXISTS v_low_stock;
DROP VIEW IF EXISTS v_daily_sales;

-- ── Recreate v_top_menu_items ─────────────────────────────────
CREATE VIEW v_top_menu_items AS
SELECT
  oi.menu_item_id,
  mi.outlet_id,
  mi.name                                                 AS menu_item_name,
  mc.name                                                 AS category_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text  AS sale_date,
  SUM(oi.quantity)::integer                               AS qty_sold,
  SUM(oi.subtotal)::numeric                               AS total_revenue
FROM order_items oi
JOIN menu_items mi  ON mi.id = oi.menu_item_id
JOIN orders o       ON o.id  = oi.order_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY 
  oi.menu_item_id, 
  mi.outlet_id, 
  mi.name, 
  mc.name, 
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_top_menu_items TO authenticated;

-- ── Recreate v_profit_loss ────────────────────────────────────
CREATE VIEW v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    outlet_id,
    TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(subtotal) AS gross_revenue,
    SUM(discount_amount) AS total_discount,
    0::numeric AS total_refund,
    SUM(total_amount) AS net_revenue
  FROM orders
  WHERE status = 'paid'
  GROUP BY outlet_id, TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
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
LEFT JOIN monthly_revenue r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;

GRANT SELECT ON v_profit_loss TO authenticated;

-- ── Recreate v_daily_sales ────────────────────────────────────
CREATE VIEW v_daily_sales AS
SELECT
  o.outlet_id,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text          AS sale_date,
  COUNT(*)::integer                                                AS total_orders,
  COALESCE(SUM(o.subtotal), 0)::numeric                           AS gross_revenue,
  COALESCE(SUM(o.discount_amount), 0)::numeric                    AS total_discount,
  COALESCE(SUM(o.tax_amount), 0)::numeric                         AS total_tax,
  COALESCE(SUM(o.service_charge), 0)::numeric                     AS total_service_charge,
  COALESCE(SUM(o.total_amount), 0)::numeric                       AS net_revenue
FROM orders o
WHERE o.status = 'paid'
GROUP BY o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_daily_sales TO authenticated;

-- ── Recreate v_low_stock ──────────────────────────────────────
CREATE VIEW v_low_stock AS
SELECT
  i.id            AS ingredient_id,
  i.outlet_id,
  i.name,
  i.unit,
  i.stock_qty::numeric,
  i.min_stock_qty::numeric,
  i.cost_per_unit::numeric,
  CASE
    WHEN i.stock_qty = 0                        THEN 'out_of_stock'
    WHEN i.stock_qty <= i.min_stock_qty         THEN 'critical'
    ELSE                                             'low'
  END AS status
FROM ingredients i
WHERE i.is_active = TRUE
  AND i.stock_qty <= i.min_stock_qty * 1.5;

GRANT SELECT ON v_low_stock TO authenticated;

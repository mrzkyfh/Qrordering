-- Views untuk laporan penjualan breakdown: departemen & pajak

-- ── v_department_sales ────────────────────────────────────────────────────────
-- Penjualan per departemen per hari
DROP VIEW IF EXISTS v_department_sales;
CREATE VIEW v_department_sales AS
SELECT
  COALESCE(md.outlet_id, mi.outlet_id)               AS outlet_id,
  md.id                                               AS department_id,
  COALESCE(md.name, 'Tanpa Departemen')               AS department_name,
  md.color,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text AS sale_date,
  COUNT(DISTINCT o.id)::integer                       AS total_orders,
  SUM(oi.quantity)::integer                           AS qty_sold,
  SUM(oi.subtotal)::numeric                           AS total_revenue
FROM order_items oi
JOIN menu_items      mi ON mi.id  = oi.menu_item_id
JOIN orders          o  ON o.id   = oi.order_id
LEFT JOIN menu_categories   mc ON mc.id = mi.category_id
LEFT JOIN menu_departments  md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY
  COALESCE(md.outlet_id, mi.outlet_id),
  md.id,
  COALESCE(md.name, 'Tanpa Departemen'),
  md.color,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_department_sales TO authenticated;

-- ── v_tax_report ──────────────────────────────────────────────────────────────
-- Pajak & service charge terkumpul per hari per outlet
DROP VIEW IF EXISTS v_tax_report;
CREATE VIEW v_tax_report AS
SELECT
  outlet_id,
  (created_at AT TIME ZONE 'Asia/Jakarta')::date::text AS sale_date,
  COUNT(*)::integer                                    AS total_orders,
  SUM(subtotal)::numeric                               AS gross_revenue,
  SUM(discount_amount)::numeric                        AS total_discount,
  SUM(tax_amount)::numeric                             AS total_tax,
  SUM(service_charge)::numeric                         AS total_service_charge,
  SUM(total_amount)::numeric                           AS net_revenue
FROM orders
WHERE status = 'paid'
GROUP BY outlet_id, (created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_tax_report TO authenticated;

-- ── v_menu_sales ──────────────────────────────────────────────────────────────
-- Penjualan per menu item per hari (mendukung date range filter di app)
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
  SUM(oi.quantity)::integer                           AS qty_sold,
  SUM(oi.subtotal)::numeric                           AS total_revenue,
  COUNT(DISTINCT o.id)::integer                       AS order_count
FROM order_items oi
JOIN menu_items        mi ON mi.id  = oi.menu_item_id
JOIN orders            o  ON o.id   = oi.order_id
LEFT JOIN menu_categories   mc ON mc.id = mi.category_id
LEFT JOIN menu_departments  md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY
  mi.outlet_id, mi.id, mi.name, mi.price,
  mc.name, md.name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_menu_sales TO authenticated;

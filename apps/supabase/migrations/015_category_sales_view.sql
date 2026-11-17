-- Migration: 010_category_sales_view.sql
-- Tujuan: Menambahkan view v_category_sales untuk breakdown revenue per kategori menu
-- Digunakan oleh: Dashboard card "Penjualan per Kategori" di Owner Panel

-- Drop view jika sudah ada (idempotent)
DROP VIEW IF EXISTS v_category_sales;

CREATE VIEW v_category_sales AS
SELECT
  mi.outlet_id,
  mc.id                                                   AS category_id,
  mc.name                                                 AS category_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text  AS sale_date,
  SUM(oi.quantity)::integer                               AS qty_sold,
  SUM(oi.subtotal)::numeric                               AS total_revenue
FROM order_items oi
JOIN menu_items      mi ON mi.id  = oi.menu_item_id
JOIN orders          o  ON o.id   = oi.order_id
LEFT JOIN menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY
  mi.outlet_id,
  mc.id,
  mc.name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_category_sales TO authenticated;

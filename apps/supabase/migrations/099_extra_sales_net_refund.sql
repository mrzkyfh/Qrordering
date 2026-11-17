-- 099_extra_sales_net_refund.sql
-- NEW-2 (Fase 2, penutup) — v_extra_option_sales dikurangi refund.
-- Ini surface penjualan TERAKHIR yang dikonsumsi (useSales/SalesBreakdownReport)
-- yang belum net refund. total_revenue extras kini memakai (quantity −
-- refunded_qty) agar konsisten dengan view penjualan lain.
--
-- DROP + CREATE (bukan REPLACE) agar bebas dari batasan kolom/tipe. 0 dependent.

DROP VIEW IF EXISTS v_extra_option_sales;
CREATE VIEW v_extra_option_sales AS
SELECT
  o.outlet_id,
  me.id                                                    AS extra_id,
  COALESCE(oio.extra_name, me.name)                        AS extra_name,
  meo.id                                                   AS option_id,
  COALESCE(oio.option_name, meo.name)                      AS option_name,
  meo.price                                                AS option_price,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text   AS sale_date,
  COUNT(oio.id)::integer                                   AS qty_selected,
  COALESCE(SUM(oio.price * (oi.quantity - COALESCE(oi.refunded_qty, 0))), 0)::numeric
                                                           AS total_revenue
FROM menu_extras me
JOIN menu_extra_options meo ON meo.extra_id = me.id
LEFT JOIN order_item_options oio ON oio.menu_extra_option_id = meo.id
LEFT JOIN order_items oi ON oi.id = oio.order_item_id
LEFT JOIN orders o ON o.id = oi.order_id AND o.status = 'paid'
GROUP BY
  o.outlet_id, me.id, COALESCE(oio.extra_name, me.name),
  meo.id, COALESCE(oio.option_name, meo.name), meo.price,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text;

GRANT SELECT ON v_extra_option_sales TO authenticated;
ALTER VIEW v_extra_option_sales SET (security_invoker = on);

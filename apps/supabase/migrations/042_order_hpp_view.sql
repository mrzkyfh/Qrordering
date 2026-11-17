-- ============================================================
-- 042_order_hpp_view.sql
-- View agregasi HPP per order (untuk Ringkasan Penjualan / Laba Kotor)
-- HPP = sum(order_item.quantity × menu_recipe.qty_per_portion × ingredient.cost_per_unit)
-- ============================================================

DROP VIEW IF EXISTS v_order_hpp;

CREATE VIEW v_order_hpp AS
SELECT
  oi.order_id,
  o.outlet_id,
  o.created_at,
  o.status,
  COALESCE(SUM(oi.quantity * mr.qty_per_portion * i.cost_per_unit), 0)::NUMERIC(14,2) AS hpp_total
FROM order_items oi
JOIN orders o          ON o.id = oi.order_id
LEFT JOIN menu_recipes mr ON mr.menu_item_id = oi.menu_item_id
LEFT JOIN ingredients  i  ON i.id = mr.ingredient_id
GROUP BY oi.order_id, o.outlet_id, o.created_at, o.status;

GRANT SELECT ON v_order_hpp TO authenticated;

COMMENT ON VIEW v_order_hpp IS
  'HPP per order dihitung dari menu_recipes × ingredients.cost_per_unit. '
  'Order tanpa resep menghasilkan hpp_total = 0.';

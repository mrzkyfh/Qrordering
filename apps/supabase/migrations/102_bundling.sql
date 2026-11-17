-- 102_bundling.sql
-- FITUR ROADMAP-3 — Paket / Bundling produk.
--
-- Bundle = menu_item biasa (punya harga sendiri) yang menjual kombinasi menu
-- lain. Stok dipotong dari resep tiap komponen; HPP = Σ HPP komponen.
--
-- Strategi: view v_effective_recipe = resep langsung ∪ ekspansi bundle→komponen.
-- deduct_stock_for_order / deduct_stock_for_items / v_order_hpp memakai view ini
-- → tak perlu ubah logika lain (restore & low_stock membalik dari
-- stock_transactions yang tercatat, jadi otomatis bundle-safe).

-- ── Flag bundle + tabel komponen ────────────────────────────────────────────
ALTER TABLE menu_items
  ADD COLUMN IF NOT EXISTS is_bundle BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS bundle_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_id    UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  component_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  qty          NUMERIC(10,3) NOT NULL DEFAULT 1 CHECK (qty > 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (bundle_id, component_id),
  CHECK (bundle_id <> component_id)   -- tak boleh berisi diri sendiri
);
CREATE INDEX IF NOT EXISTS idx_bundle_items_bundle ON bundle_items(bundle_id);

ALTER TABLE bundle_items ENABLE ROW LEVEL SECURITY;
-- Konsisten dgn menu_recipes (authenticated manage). menu_items RLS membatasi
-- bundle yang terlihat; edge fn / UI membatasi siapa yang mengubah.
DROP POLICY IF EXISTS "authenticated can manage bundle_items" ON bundle_items;
CREATE POLICY "authenticated can manage bundle_items"
  ON bundle_items FOR ALL TO authenticated
  USING (TRUE) WITH CHECK (TRUE);
GRANT SELECT, INSERT, UPDATE, DELETE ON bundle_items TO authenticated;

-- ── View resep efektif (resep langsung + ekspansi bundle) ───────────────────
DROP VIEW IF EXISTS v_effective_recipe;
CREATE VIEW v_effective_recipe AS
  -- Resep langsung (menu biasa; bundle biasanya tak punya resep langsung).
  SELECT mr.menu_item_id, mr.ingredient_id, mr.qty_per_portion
  FROM menu_recipes mr
  UNION ALL
  -- Ekspansi bundle: bundle → resep tiap komponen × qty komponen.
  SELECT bi.bundle_id AS menu_item_id,
         mr.ingredient_id,
         (bi.qty * mr.qty_per_portion) AS qty_per_portion
  FROM bundle_items bi
  JOIN menu_recipes mr ON mr.menu_item_id = bi.component_id;

GRANT SELECT ON v_effective_recipe TO authenticated;
ALTER VIEW v_effective_recipe SET (security_invoker = on);

-- ── deduct_stock_for_order: pakai v_effective_recipe ────────────────────────
CREATE OR REPLACE FUNCTION deduct_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_order  RECORD;
  v_item   RECORD;
  v_recipe RECORD;
  v_ing    RECORD;
  v_deduct NUMERIC;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND OR v_order.stock_deducted THEN RETURN; END IF;

  FOR v_item IN
    SELECT * FROM order_items WHERE order_id = p_order_id
  LOOP
    FOR v_recipe IN
      SELECT * FROM v_effective_recipe WHERE menu_item_id = v_item.menu_item_id
    LOOP
      v_deduct := v_recipe.qty_per_portion * v_item.quantity;
      SELECT * INTO v_ing FROM ingredients WHERE id = v_recipe.ingredient_id;
      IF NOT FOUND THEN CONTINUE; END IF;

      INSERT INTO stock_transactions
        (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
      VALUES
        (v_order.outlet_id, v_recipe.ingredient_id, 'usage',
         v_deduct, v_ing.stock_qty, v_ing.stock_qty - v_deduct,
         'Auto: Order #' || v_order.order_number, p_order_id);
    END LOOP;
  END LOOP;

  UPDATE orders SET stock_deducted = TRUE WHERE id = p_order_id;
END;
$$;

-- ── deduct_stock_for_items (open bill): pakai v_effective_recipe ─────────────
CREATE OR REPLACE FUNCTION deduct_stock_for_items(
  p_order_id UUID,
  p_item_ids UUID[]
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_order  RECORD;
  v_item   RECORD;
  v_recipe RECORD;
  v_ing    RECORD;
  v_deduct NUMERIC;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN; END IF;

  FOR v_item IN
    SELECT * FROM order_items
    WHERE order_id = p_order_id AND id = ANY(p_item_ids)
  LOOP
    FOR v_recipe IN
      SELECT * FROM v_effective_recipe WHERE menu_item_id = v_item.menu_item_id
    LOOP
      v_deduct := v_recipe.qty_per_portion * v_item.quantity;
      SELECT * INTO v_ing FROM ingredients WHERE id = v_recipe.ingredient_id;
      IF NOT FOUND THEN CONTINUE; END IF;

      INSERT INTO stock_transactions
        (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
      VALUES
        (v_order.outlet_id, v_recipe.ingredient_id, 'usage',
         v_deduct, v_ing.stock_qty, v_ing.stock_qty - v_deduct,
         'Tambahan: Order #' || v_order.order_number, p_order_id);
    END LOOP;
  END LOOP;
END;
$$;

-- ── v_order_hpp: HPP lewat v_effective_recipe (termasuk komponen bundle) ────
DROP VIEW IF EXISTS v_order_hpp;
CREATE VIEW v_order_hpp AS
SELECT
  oi.order_id,
  o.outlet_id,
  o.created_at,
  o.status,
  COALESCE(SUM(oi.quantity * er.qty_per_portion * i.cost_per_unit), 0)::NUMERIC(14,2) AS hpp_total
FROM order_items oi
JOIN orders o             ON o.id = oi.order_id
LEFT JOIN v_effective_recipe er ON er.menu_item_id = oi.menu_item_id
LEFT JOIN ingredients  i  ON i.id = er.ingredient_id
GROUP BY oi.order_id, o.outlet_id, o.created_at, o.status;

GRANT SELECT ON v_order_hpp TO authenticated;
ALTER VIEW v_order_hpp SET (security_invoker = on);

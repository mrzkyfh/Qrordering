-- ============================================================
-- 009_inventory_recipes.sql
-- Resep menu + pengurangan stok otomatis via trigger
-- ============================================================

-- ── 1. Tambah kolom ke tabel yang sudah ada ──────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS stock_deducted BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE stock_transactions
  ADD COLUMN IF NOT EXISTS order_id UUID REFERENCES orders(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_stock_tx_order ON stock_transactions(order_id);

-- ── 2. Tabel resep menu ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS menu_recipes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  menu_item_id    UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  ingredient_id   UUID NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
  qty_per_portion NUMERIC NOT NULL CHECK (qty_per_portion > 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(menu_item_id, ingredient_id)
);

ALTER TABLE menu_recipes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated can manage recipes"
  ON menu_recipes FOR ALL TO authenticated
  USING (TRUE) WITH CHECK (TRUE);

-- ── 3. Fungsi: kurangi stok saat order masuk preparing ───────

CREATE OR REPLACE FUNCTION deduct_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order       RECORD;
  v_item        RECORD;
  v_recipe      RECORD;
  v_ing         RECORD;
  v_deduct      NUMERIC;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND OR v_order.stock_deducted THEN RETURN; END IF;

  FOR v_item IN
    SELECT * FROM order_items WHERE order_id = p_order_id
  LOOP
    FOR v_recipe IN
      SELECT * FROM menu_recipes WHERE menu_item_id = v_item.menu_item_id
    LOOP
      v_deduct := v_recipe.qty_per_portion * v_item.quantity;

      SELECT * INTO v_ing FROM ingredients WHERE id = v_recipe.ingredient_id;
      IF NOT FOUND THEN CONTINUE; END IF;

      UPDATE ingredients
        SET stock_qty = stock_qty - v_deduct
        WHERE id = v_recipe.ingredient_id;

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

-- ── 4. Fungsi: kembalikan stok saat order di-cancel/void ─────

CREATE OR REPLACE FUNCTION restore_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order   RECORD;
  v_tx      RECORD;
  v_ing     RECORD;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND OR NOT v_order.stock_deducted THEN RETURN; END IF;

  FOR v_tx IN
    SELECT * FROM stock_transactions
    WHERE order_id = p_order_id AND type = 'usage'
  LOOP
    SELECT * INTO v_ing FROM ingredients WHERE id = v_tx.ingredient_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    UPDATE ingredients
      SET stock_qty = stock_qty + v_tx.qty
      WHERE id = v_tx.ingredient_id;

    INSERT INTO stock_transactions
      (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
    VALUES
      (v_tx.outlet_id, v_tx.ingredient_id, 'return',
       v_tx.qty, v_ing.stock_qty, v_ing.stock_qty + v_tx.qty,
       'Batal: Order #' || v_order.order_number, p_order_id);
  END LOOP;

  UPDATE orders SET stock_deducted = FALSE WHERE id = p_order_id;
END;
$$;

-- ── 5. Trigger function ───────────────────────────────────────

CREATE OR REPLACE FUNCTION handle_order_stock_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Kurangi stok saat masuk preparing
  IF NEW.status = 'preparing' AND OLD.status IS DISTINCT FROM 'preparing' THEN
    PERFORM deduct_stock_for_order(NEW.id);
  END IF;

  -- Kembalikan stok jika di-cancel atau void
  IF NEW.status IN ('cancelled', 'void') AND OLD.status NOT IN ('cancelled', 'void') THEN
    PERFORM restore_stock_for_order(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_stock ON orders;
CREATE TRIGGER trg_order_stock
  AFTER UPDATE OF status ON orders
  FOR EACH ROW
  EXECUTE FUNCTION handle_order_stock_trigger();

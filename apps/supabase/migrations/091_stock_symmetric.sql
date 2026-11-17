-- 091_stock_symmetric.sql
-- FIX ANOMALI-2 — Restore meng-inflasi stok saat deduct kena "lantai nol".
--
-- Sebelumnya usage/waste memakai GREATEST(stock_qty - qty, 0) → bila stok tak
-- cukup (oversell), pemotongan berhenti di 0 tapi transaksi tetap mencatat qty
-- penuh. Saat void mengembalikan qty penuh → stok jadi LEBIH tinggi dari semula
-- (stok hantu). Contoh: stok 5, butuh 8 → jadi 0; void → +8 → jadi 8 (harusnya 5).
--
-- Solusi: deduct & restore dibuat SIMETRIS — izinkan stok negatif. Nilai negatif
-- adalah sinyal jujur "oversell / perlu restock", dan deduct↔restore kini pas.

-- ── Trigger penerap stok: usage/waste tanpa lantai-0 ────────────────────────
CREATE OR REPLACE FUNCTION apply_stock_transaction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type IN ('purchase', 'return', 'adjustment') THEN
    UPDATE ingredients
    SET stock_qty  = stock_qty + NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type IN ('usage', 'waste') THEN
    -- Tanpa GREATEST → simetris dengan restore; boleh negatif (sinyal oversell).
    UPDATE ingredients
    SET stock_qty  = stock_qty - NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  END IF;
  RETURN NEW;
END;
$$;

-- ── deduct_stock_for_order: qty_after tanpa lantai-0 (konsisten) ────────────
CREATE OR REPLACE FUNCTION deduct_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
      SELECT * FROM menu_recipes WHERE menu_item_id = v_item.menu_item_id
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

-- ── deduct_stock_for_items (open bill): qty_after tanpa lantai-0 ────────────
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
      SELECT * FROM menu_recipes WHERE menu_item_id = v_item.menu_item_id
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

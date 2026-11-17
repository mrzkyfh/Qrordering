-- ============================================================
-- 010_fix_double_stock_mutation.sql
--
-- BUG: deduct_stock_for_order() dan restore_stock_for_order()
-- melakukan dua mutasi sekaligus ke ingredients.stock_qty:
--   1. UPDATE ingredients langsung di dalam fungsi
--   2. INSERT ke stock_transactions memicu trigger
--      apply_stock_transaction() yang UPDATE lagi
--
-- FIX: Hapus UPDATE langsung — cukup andalkan trigger
--      apply_stock_transaction() yang sudah ada di migration 004.
-- ============================================================

CREATE OR REPLACE FUNCTION deduct_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order   RECORD;
  v_item    RECORD;
  v_recipe  RECORD;
  v_ing     RECORD;
  v_deduct  NUMERIC;
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

      -- INSERT saja — trigger apply_stock_transaction() yang update stock_qty
      INSERT INTO stock_transactions
        (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
      VALUES
        (v_order.outlet_id, v_recipe.ingredient_id, 'usage',
         v_deduct,
         v_ing.stock_qty,
         GREATEST(v_ing.stock_qty - v_deduct, 0),
         'Auto: Order #' || v_order.order_number,
         p_order_id);
    END LOOP;
  END LOOP;

  UPDATE orders SET stock_deducted = TRUE WHERE id = p_order_id;
END;
$$;


CREATE OR REPLACE FUNCTION restore_stock_for_order(p_order_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order RECORD;
  v_tx    RECORD;
  v_ing   RECORD;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND OR NOT v_order.stock_deducted THEN RETURN; END IF;

  FOR v_tx IN
    SELECT * FROM stock_transactions
    WHERE order_id = p_order_id AND type = 'usage'
  LOOP
    SELECT * INTO v_ing FROM ingredients WHERE id = v_tx.ingredient_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- INSERT saja — trigger apply_stock_transaction() yang update stock_qty
    INSERT INTO stock_transactions
      (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
    VALUES
      (v_tx.outlet_id, v_tx.ingredient_id, 'return',
       v_tx.qty,
       v_ing.stock_qty,
       v_ing.stock_qty + v_tx.qty,
       'Batal: Order #' || v_order.order_number,
       p_order_id);
  END LOOP;

  UPDATE orders SET stock_deducted = FALSE WHERE id = p_order_id;
END;
$$;

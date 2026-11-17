-- 090_stock_open_bill_and_refund.sql
-- FIX STOK BAHAN BAKU (dua anomali):
--
-- ANOMALI-1 — Open bill: item yang ditambahkan lewat "Tambah Pesanan" tak
-- pernah memotong stok. `stock_deducted` adalah flag SEKALI per-order (di-set
-- saat confirm pertama), dan trigger stok hanya fire saat status berubah —
-- menambah order_items tak mengubah status → stok bocor (tampil > nyata).
-- Solusi: RPC yang memotong stok HANYA untuk item tertentu (item baru),
-- tanpa bergantung pada flag stock_deducted. Dipanggil app setelah menambah item.
--
-- ANOMALI Refund — bahan yang sudah dipakai tidak bisa dipakai lagi. Refund
-- (status 'cancelled') TIDAK boleh mengembalikan stok. Void tetap mengembalikan
-- (pembatalan order salah-buat sebelum dipakai).

-- ── Bagian 1: deduct stok untuk item tertentu (open bill) ───────────────────
CREATE OR REPLACE FUNCTION deduct_stock_for_items(
  p_order_id UUID,
  p_item_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
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

      -- INSERT saja — trigger apply_stock_transaction() yang update stock_qty.
      INSERT INTO stock_transactions
        (outlet_id, ingredient_id, type, qty, qty_before, qty_after, notes, order_id)
      VALUES
        (v_order.outlet_id, v_recipe.ingredient_id, 'usage',
         v_deduct,
         v_ing.stock_qty,
         GREATEST(v_ing.stock_qty - v_deduct, 0),
         'Tambahan: Order #' || v_order.order_number,
         p_order_id);
    END LOOP;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION deduct_stock_for_items(UUID, UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION deduct_stock_for_items(UUID, UUID[]) TO authenticated;

-- ── Bagian 2: refund (cancelled) TIDAK mengembalikan stok ───────────────────
-- Deduct tetap saat confirmed/preparing/paid. Restore HANYA saat 'void'
-- (bukan 'cancelled' = refund), karena bahan yang sudah dipakai tak kembali.
CREATE OR REPLACE FUNCTION handle_order_stock_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status IN ('confirmed', 'preparing', 'paid')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM deduct_stock_for_order(NEW.id);
  END IF;

  -- Refund = 'cancelled' → JANGAN restore (bahan sudah terpakai).
  -- Void = pembatalan order → tetap restore.
  IF NEW.status = 'void' AND OLD.status NOT IN ('cancelled', 'void') THEN
    PERFORM restore_stock_for_order(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

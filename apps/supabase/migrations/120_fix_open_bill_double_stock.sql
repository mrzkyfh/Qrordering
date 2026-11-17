-- 120_fix_open_bill_double_stock.sql
-- Item open bill terpotong stok DUA KALI. Plus: resep bundling terlewat di
-- jalur open bill.
--
-- ── Bug 1: potong ganda ──────────────────────────────────────────────────────
-- `deduct_stock_for_order` dijaga flag `orders.stock_deducted`, tapi
-- `deduct_stock_for_items` (dipakai "Tambah Pesanan") TIDAK pernah menyentuh
-- flag itu. Runtutannya:
--   1. createOrder INSERT langsung status='confirmed'. Trigger stok adalah
--      AFTER UPDATE OF status → TIDAK jalan saat INSERT → flag tetap false.
--   2. Kasir menambah item → deduct_stock_for_items memotong item baru saja.
--   3. Bayar → status berubah → trigger → deduct_stock_for_order → flag masih
--      false → memotong SEMUA item, termasuk yang sudah dipotong di langkah 2.
-- Item open bill terpotong dua kali → stok tampak lebih sedikit dari nyata,
-- alert "stok menipis" palsu, dan HPP meleset.
-- Self-order tidak kena karena lewat draft→confirmed: trigger sempat jalan dan
-- menyalakan flag sebelum item ditambahkan.
--
-- Perbaikan: flag per-ITEM, bukan per-order. Flag order dipertahankan agar
-- perilaku lama (restore, dsb.) tak berubah.
--
-- ── Bug 2: bundling terlewat ────────────────────────────────────────────────
-- 102 memperkenalkan v_effective_recipe (resep + komponen bundling) dan
-- memakainya di deduct_stock_for_order — tapi deduct_stock_for_items tetap
-- membaca menu_recipes langsung. Jadi menu bundling yang ditambahkan lewat open
-- bill tidak memotong bahan komponennya sama sekali.

-- ── 1. Flag per item ─────────────────────────────────────────────────────────
-- Nullable→NOT NULL DEFAULT false: menambah kolom dengan default konstan tidak
-- menulis ulang tabel di PG 11+ dan tidak memicu trigger apa pun.
ALTER TABLE order_items
  ADD COLUMN IF NOT EXISTS stock_deducted BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN order_items.stock_deducted IS
  'Bahan untuk item ini sudah dipotong. Per-item (bukan per-order) supaya item '
  'yang ditambahkan lewat open bill tidak terpotong dua kali saat order lunas.';

-- Backfill: item milik order yang sudah dipotong ditandai, agar perubahan
-- status berikutnya tidak memotongnya lagi lewat logika per-item yang baru.
UPDATE order_items oi
   SET stock_deducted = TRUE
  FROM orders o
 WHERE o.id = oi.order_id
   AND o.stock_deducted
   AND NOT oi.stock_deducted;

-- ── 2. deduct_stock_for_order: lewati item yang sudah dipotong ───────────────
-- Salinan setia 102 — perubahan ditandai "◄ 120".
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
    -- ◄ 120: item yang sudah dipotong lewat open bill dilewati.
    SELECT * FROM order_items
     WHERE order_id = p_order_id AND NOT stock_deducted
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

    UPDATE order_items SET stock_deducted = TRUE WHERE id = v_item.id;  -- ◄ 120
  END LOOP;

  UPDATE orders SET stock_deducted = TRUE WHERE id = p_order_id;
END;
$$;

-- ── 3. deduct_stock_for_items: tandai item + pakai resep efektif ─────────────
-- Salinan setia 090 — perubahan ditandai "◄ 120".
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
    -- ◄ 120: idempoten — item yang sudah dipotong tak dipotong lagi.
    SELECT * FROM order_items
    WHERE order_id = p_order_id AND id = ANY(p_item_ids) AND NOT stock_deducted
  LOOP
    FOR v_recipe IN
      -- ◄ 120: v_effective_recipe (bukan menu_recipes) agar komponen BUNDLING
      -- ikut terpotong — 102 memperkenalkannya tapi jalur ini terlewat.
      SELECT * FROM v_effective_recipe WHERE menu_item_id = v_item.menu_item_id
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

    UPDATE order_items SET stock_deducted = TRUE WHERE id = v_item.id;  -- ◄ 120
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION deduct_stock_for_items(UUID, UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION deduct_stock_for_items(UUID, UUID[]) TO authenticated;

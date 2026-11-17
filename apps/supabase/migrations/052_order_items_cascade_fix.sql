-- ============================================================
-- 052_order_items_cascade_fix.sql
-- Lengkapi cascade hapus cabang: ubah 2 FK "cucu" yg masih NO ACTION
-- menjadi ON DELETE CASCADE.
--
--   order_items.menu_item_id        → menu_items(id)
--   stock_transactions.ingredient_id → ingredients(id)
--
-- Saat hapus outlet, menu_items & ingredients ikut terhapus (cascade
-- dari outlets). Constraint NO ACTION di atas ternyata menolak SEKETIKA
-- (bukan ditunda ke akhir statement) sehingga memblokir penghapusan.
-- Dibuat CASCADE agar order_items / stock_transactions terkait ikut
-- terhapus bersama menu_items / ingredients-nya.
--
-- AMAN: app mengarsipkan (soft-delete) menu & bahan yg punya history
-- transaksi (lihat 037_smart_delete_rpcs.sql) — hard-delete hanya untuk
-- yg belum pernah dipakai. Jadi CASCADE ini praktis hanya aktif saat
-- penghapusan cabang.
-- ============================================================

ALTER TABLE order_items
  DROP CONSTRAINT IF EXISTS order_items_menu_item_id_fkey,
  ADD  CONSTRAINT order_items_menu_item_id_fkey
    FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE CASCADE;

ALTER TABLE stock_transactions
  DROP CONSTRAINT IF EXISTS stock_transactions_ingredient_id_fkey,
  ADD  CONSTRAINT stock_transactions_ingredient_id_fkey
    FOREIGN KEY (ingredient_id) REFERENCES ingredients(id) ON DELETE CASCADE;

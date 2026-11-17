-- ============================================================
-- 050_outlet_cascade_delete.sql
-- Izinkan menghapus cabang (outlet) walau punya history transaksi,
-- dengan otomatis menghapus SEMUA data terkait.
--
-- 6 FK ke outlets(id) sebelumnya NO ACTION (memblokir delete bila
-- ada data): shifts, orders, payments, stock_transactions, vouchers,
-- expenses. Diubah menjadi ON DELETE CASCADE.
--
-- Tabel lain yg ber-FK ke outlets sudah CASCADE/SET NULL. Constraint
-- NO ACTION sisa (order_items.menu_item_id, stock_transactions.
-- ingredient_id) dicek di akhir statement sehingga lolos otomatis
-- karena baris anaknya ikut terhapus dalam cascade yg sama.
--
-- Nama constraint memakai default Postgres ({tabel}_outlet_id_fkey).
-- DROP ... IF EXISTS membuatnya aman dijalankan berulang (idempoten).
--
-- ⚠️ DESTRUKTIF: setelah migrasi ini, DELETE outlet akan menghapus
-- seluruh pesanan, shift, pembayaran, stok, voucher, & pengeluaran
-- milik cabang tsb secara permanen.
-- ============================================================

ALTER TABLE shifts
  DROP CONSTRAINT IF EXISTS shifts_outlet_id_fkey,
  ADD  CONSTRAINT shifts_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

ALTER TABLE orders
  DROP CONSTRAINT IF EXISTS orders_outlet_id_fkey,
  ADD  CONSTRAINT orders_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

ALTER TABLE payments
  DROP CONSTRAINT IF EXISTS payments_outlet_id_fkey,
  ADD  CONSTRAINT payments_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

ALTER TABLE stock_transactions
  DROP CONSTRAINT IF EXISTS stock_transactions_outlet_id_fkey,
  ADD  CONSTRAINT stock_transactions_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

ALTER TABLE vouchers
  DROP CONSTRAINT IF EXISTS vouchers_outlet_id_fkey,
  ADD  CONSTRAINT vouchers_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

ALTER TABLE expenses
  DROP CONSTRAINT IF EXISTS expenses_outlet_id_fkey,
  ADD  CONSTRAINT expenses_outlet_id_fkey
    FOREIGN KEY (outlet_id) REFERENCES outlets(id) ON DELETE CASCADE;

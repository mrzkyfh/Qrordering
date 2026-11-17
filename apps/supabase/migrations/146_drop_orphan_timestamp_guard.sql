-- 146_drop_orphan_timestamp_guard.sql
-- Bersih-bersih pasca 145: fungsi trigger generik guard_future_transaction_timestamp()
-- dari 143 sudah tidak dirujuk trigger mana pun sejak 145 memecahnya menjadi
-- guard_order_future_timestamp() + guard_payment_future_timestamp() per tabel.
-- Fungsi lama dibiarkan yatim di 145 agar fix bisa ditempel cepat; di sini
-- dihapus lewat migrasi MAJU (bukan mengedit 143/145 yang sudah di produksi).
--
-- CASCADE sengaja TIDAK dipakai: bila ternyata masih ada trigger tersisa, DROP
-- akan gagal dan memberi tahu, bukan diam-diam menghapus trigger yang dipakai.
DROP FUNCTION IF EXISTS public.guard_future_transaction_timestamp();

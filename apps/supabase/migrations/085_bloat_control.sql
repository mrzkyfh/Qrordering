-- 085_bloat_control.sql
-- STRATEGI RETENSI #4 — kontrol bloat pada tabel high-churn.
-- orders di-UPDATE berkali-kali (draft→confirmed→paid + updated_at) → banyak
-- dead tuple. fillfactor < 100 menyisakan ruang di page untuk HOT-update
-- (update tanpa bikin index entry baru) → bloat jauh lebih kecil.
-- autovacuum dibuat lebih agresif agar dead tuple cepat direklamasi.

-- ── orders: paling sering di-UPDATE ─────────────────────────────────────────
ALTER TABLE orders SET (
  fillfactor = 85,
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05,
  autovacuum_vacuum_cost_delay = 2
);

-- ── restaurant_tables: status berubah tiap order (occupied/available) ────────
ALTER TABLE restaurant_tables SET (
  fillfactor = 85,
  autovacuum_vacuum_scale_factor = 0.10
);

-- ── ingredients: stock_qty ter-UPDATE tiap transaksi stok ───────────────────
ALTER TABLE ingredients SET (
  fillfactor = 90,
  autovacuum_vacuum_scale_factor = 0.10
);

-- CATATAN: fillfactor baru berlaku untuk page baru. Untuk merapikan page lama
-- + reklaim bloat yang sudah ada, jalankan SEKALI saat outlet tutup (mengunci
-- tabel sebentar):
--     VACUUM (FULL, ANALYZE) orders;
--     VACUUM (FULL, ANALYZE) restaurant_tables;
-- Tidak dimasukkan otomatis ke migrasi karena VACUUM FULL mengunci tabel.
-- pg_cron nightly VACUUM (biasa, tanpa FULL) untuk menjaga bloat tetap rendah:
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'nightly-vacuum-hot-tables',
  '40 2 * * *',
  $$VACUUM (ANALYZE) orders; VACUUM (ANALYZE) restaurant_tables; VACUUM (ANALYZE) ingredients;$$
);

-- ============================================================
-- 195 — Arahkan referensi gambar ke Cloudflare R2
--
-- PENTING: jalankan hanya setelah semua objek berhasil disalin dan checksum
-- diverifikasi oleh apps/assets-worker/scripts/migrate-supabase-images.mjs.
-- Data bisnis, auth, transaksi, dan konfigurasi tetap berada di Supabase;
-- migration ini hanya mengganti string URL aset gambarnya.
-- ============================================================

BEGIN;

UPDATE public.menu_items
SET image_url =
  'https://qrordering-assets.timess402coffee.workers.dev/assets/menu/' ||
  split_part(split_part(image_url, '/menu-images/', 2), '?', 1),
  updated_at = NOW()
WHERE image_url IS NOT NULL
  AND image_url LIKE '%/storage/v1/object/public/menu-images/%';

COMMIT;

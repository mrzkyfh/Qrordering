-- 149_confirm_error_log_retention.sql
-- Pembersihan historis satu kali sudah dijalankan langsung pada database
-- produksi pada 2026-07-23 setelah error notifikasi lifecycle diperbaiki.
--
-- Jangan menaruh TRUNCATE di migrasi yang dapat diputar ulang: riwayat migrasi
-- proyek remote lama belum sinkron dengan file lokal, sehingga db push di masa
-- depan tidak boleh berisiko menghapus log baru. Migrasi ini hanya menegaskan
-- jadwal retensi yang aman dan idempoten.

-- Tegaskan kembali retensi aktif: simpan maksimal 14 hari dan pangkas setiap
-- hari pukul 02:20 WIB (19:20 UTC).
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'prune-error-logs',
  '20 19 * * *',
  $$SELECT public.prune_error_logs(14);$$
);

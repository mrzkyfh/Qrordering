-- 106_error_logs_retention.sql
-- STRATEGI RETENSI #5 — pangkas error_logs (dibuat di 098, belum tercakup
-- job maintenance 083-087). Tiap crash device menulis 1 baris → append-only,
-- bisa tumbuh tanpa batas. Simpan 30 hari; log lama tak berguna untuk debug.
-- Melengkapi: 083 (audit), 084 (summary), 085 (bloat/vacuum), 087 (monitoring).

-- ── Fungsi prune (terjadwal + bisa dipanggil manual) ────────────────────────
CREATE OR REPLACE FUNCTION public.prune_error_logs(p_keep_days INT DEFAULT 30)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM error_logs
  WHERE created_at < now() - make_interval(days => p_keep_days);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- Hanya service_role/postgres (job) yang boleh memanggil.
REVOKE ALL ON FUNCTION public.prune_error_logs(INT) FROM PUBLIC;

-- ── Autovacuum agresif untuk tabel log (dead tuple cepat direklamasi) ────────
ALTER TABLE error_logs SET (
  autovacuum_vacuum_scale_factor = 0.10,
  autovacuum_analyze_scale_factor = 0.10
);

-- ── Jadwalkan harian 02:20 (upsert by name → aman dijalankan ulang) ─────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'prune-error-logs',
  '20 2 * * *',
  $$SELECT public.prune_error_logs(30);$$
);

-- ── Sertakan error_logs + shifts ke nightly VACUUM (perbarui job 085) ───────
-- Re-schedule job yang sudah ada (nama sama = di-upsert), tambah 2 tabel.
SELECT cron.schedule(
  'nightly-vacuum-hot-tables',
  '40 2 * * *',
  $$VACUUM (ANALYZE) orders; VACUUM (ANALYZE) restaurant_tables; VACUUM (ANALYZE) ingredients; VACUUM (ANALYZE) shifts; VACUUM (ANALYZE) error_logs;$$
);

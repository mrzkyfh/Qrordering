-- 087_db_monitoring.sql
-- STRATEGI RETENSI #5 & #6 — monitoring ukuran DB + diagnostik index tak terpakai.
-- Semua read-only (view + fungsi log). Tidak menghapus apa pun.

-- ── Ukuran per tabel (data + index + toast), terbesar dulu ──────────────────
CREATE OR REPLACE VIEW v_table_sizes AS
SELECT
  c.relname AS tabel,
  pg_total_relation_size(c.oid)                                   AS total_bytes,
  pg_size_pretty(pg_total_relation_size(c.oid))                   AS total,
  pg_size_pretty(pg_relation_size(c.oid))                         AS data,
  pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) AS index_toast,
  s.n_live_tup AS live_rows,
  s.n_dead_tup AS dead_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- ── Index yang belum pernah dipakai (kandidat drop untuk hemat ruang) ───────
-- Cek berkala; JANGAN drop index UNIQUE/constraint. idx_scan=0 = belum terpakai
-- sejak statistik terakhir di-reset.
CREATE OR REPLACE VIEW v_unused_indexes AS
SELECT
  s.relname   AS tabel,
  s.indexrelname AS index,
  s.idx_scan,
  pg_size_pretty(pg_relation_size(s.indexrelid)) AS ukuran,
  i.indisunique AS is_unique
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname = 'public'
  AND s.idx_scan = 0
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- ── Log ukuran DB harian + peringatan ambang (70% / 85% dari 500 MB) ────────
CREATE TABLE IF NOT EXISTS db_size_log (
  logged_at   TIMESTAMPTZ PRIMARY KEY DEFAULT now(),
  size_bytes  BIGINT NOT NULL,
  pct_of_free NUMERIC(5,2) NOT NULL   -- terhadap 500 MB
);

CREATE OR REPLACE FUNCTION public.log_db_size()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_bytes BIGINT := pg_database_size(current_database());
  v_pct   NUMERIC(5,2) := round(v_bytes * 100.0 / (500 * 1024 * 1024), 2);
  v_level TEXT := 'ok';
BEGIN
  INSERT INTO db_size_log (logged_at, size_bytes, pct_of_free)
  VALUES (now(), v_bytes, v_pct);

  IF v_pct >= 85 THEN
    v_level := 'CRITICAL';
    RAISE WARNING 'DB size % %% dari kuota free (>= 85%%) — segera arsip/upgrade', v_pct;
  ELSIF v_pct >= 70 THEN
    v_level := 'WARNING';
    RAISE WARNING 'DB size % %% dari kuota free (>= 70%%) — rencanakan arsip', v_pct;
  END IF;

  RETURN format('%s: %s (%s%% dari 500MB)', v_level, pg_size_pretty(v_bytes), v_pct);
END;
$$;

REVOKE ALL ON FUNCTION public.log_db_size() FROM PUBLIC;

-- Jadwalkan pencatatan harian 03:00.
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'log-db-size',
  '0 3 * * *',
  $$SELECT public.log_db_size();$$
);

-- 098_error_logs.sql
-- FITUR R3-1 — Visibilitas error produksi tanpa dependency eksternal (Sentry).
-- Aplikasi mobile tersebar di banyak device klien; global error handler
-- (main.dart) mengirim error tak tertangkap ke tabel ini agar tim bisa melihat
-- masalah lapangan tanpa akses fisik ke device.

CREATE TABLE IF NOT EXISTS error_logs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message    TEXT NOT NULL,
  stack      TEXT,
  app_build  INTEGER,
  platform   TEXT,
  user_id    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  outlet_id  UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_error_logs_created ON error_logs(created_at DESC);

ALTER TABLE error_logs ENABLE ROW LEVEL SECURITY;

-- INSERT: user login boleh menulis log, tapi tak boleh mengatasnamakan user lain.
DROP POLICY IF EXISTS "error_logs_insert" ON error_logs;
CREATE POLICY "error_logs_insert" ON error_logs
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR user_id IS NULL);

-- SELECT: hanya owner (lintas outlet) yang melihat log error.
DROP POLICY IF EXISTS "error_logs_select" ON error_logs;
CREATE POLICY "error_logs_select" ON error_logs
  FOR SELECT TO authenticated
  USING (is_owner());

GRANT SELECT, INSERT ON error_logs TO authenticated;

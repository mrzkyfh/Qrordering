-- 093_app_config.sql
-- FITUR R3-4 — Force-update gate. Saat fix penting dirilis (mis. stok bocor,
-- refund), device klien versi lama harus dipaksa update. Tabel konfigurasi
-- global sederhana; app membaca `min_build` saat start dan membandingkan dengan
-- build number-nya sendiri.

CREATE TABLE IF NOT EXISTS app_config (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Build minimum Android yang wajib. Naikkan angka ini saat merilis versi yang
-- WAJIB diinstal (device dengan build di bawahnya akan diblokir sampai update).
INSERT INTO app_config (key, value)
VALUES ('min_build_android', '1')
ON CONFLICT (key) DO NOTHING;

-- ── RLS: boleh dibaca semua (termasuk anon, agar bisa dicek sebelum login) ──
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_config_read" ON app_config;
CREATE POLICY "app_config_read" ON app_config
  FOR SELECT TO anon, authenticated
  USING (true);

GRANT SELECT ON app_config TO anon, authenticated;
-- Tulis hanya via dashboard/service_role (tak ada policy INSERT/UPDATE utk klien).

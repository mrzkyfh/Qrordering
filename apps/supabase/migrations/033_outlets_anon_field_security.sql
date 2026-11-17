-- ============================================================
-- 033_outlets_anon_field_security.sql
-- Fix BUG-XCC-001: outlets anon RLS leak
--
-- Sebelumnya: anon bisa SELECT * dari outlets (termasuk loyalty_settings,
-- payment_methods, dan field internal di JSONB settings).
--
-- Sekarang:
--   1. REVOKE SELECT penuh dari anon
--   2. GRANT SELECT pada kolom aman saja (id, name, address, phone, city, logo_url, is_active)
--   3. Buat view v_outlets_public dengan settings yang di-curate (tanpa loyalty_settings,
--      tanpa payment_methods, tanpa field sensitif)
--   4. GRANT SELECT pada view ke anon + authenticated
--
-- Mobile customer (self-order) tetap bisa baca data outlet yang diperlukan
-- via v_outlets_public, atau via embed kolom eksplisit di restaurant_tables.
-- ============================================================

-- ── Step 1: Kunci akses kolom anon ke tabel outlets ────────────────────────
-- Catatan: policy outlets_select_anon di migration 008 tetap dipertahankan
-- untuk back-compat embed. Yang berubah adalah kolom-level GRANT.
REVOKE SELECT ON outlets FROM anon;
GRANT  SELECT (id, name, address, phone, city, logo_url, is_active)
  ON outlets TO anon;

-- ── Step 2: View publik dengan settings yang di-curate ──────────────────────
-- Catatan: view ini sengaja TIDAK pakai security_invoker = true karena
-- view butuh akses ke kolom settings di tabel outlets yang sudah di-revoke
-- dari anon. Dengan security definer (default), view bertindak sebagai
-- security boundary — anon dapat membaca hasil yang sudah di-whitelist.
DROP VIEW IF EXISTS v_outlets_public;

CREATE VIEW v_outlets_public AS
SELECT
  o.id,
  o.name,
  o.address,
  o.phone,
  o.city,
  o.logo_url,
  o.is_active,
  -- Whitelist field di settings yang aman dibaca publik
  jsonb_build_object(
    'tax_percent',            o.settings->'tax_percent',
    'tax_rate',               o.settings->'tax_rate',
    'service_charge_percent', o.settings->'service_charge_percent',
    'service_rate',           o.settings->'service_rate',
    'currency',               o.settings->'currency',
    'receipt_footer',         o.settings->'receipt_footer'
  ) AS settings,
  o.created_at,
  o.updated_at
FROM outlets o
WHERE o.is_active = true;

COMMENT ON VIEW v_outlets_public IS
  'Public-safe projection of outlets — hides loyalty_settings & payment_methods. Used by anon (customer self-order menu).';

-- ── Step 3: Berikan SELECT ke anon + authenticated ──────────────────────────
GRANT SELECT ON v_outlets_public TO anon, authenticated;

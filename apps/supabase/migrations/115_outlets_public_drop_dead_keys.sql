-- 115_outlets_public_drop_dead_keys.sql
-- Buang `tax_rate` & `service_rate` dari v_outlets_public — kunci yang MATI.
--
-- Keduanya hanya pernah DIBACA, tidak pernah ditulis siapa pun: owner-panel
-- menyimpan `tax_percent` / `service_charge_percent`. Jadi `settings->'tax_rate'`
-- selalu NULL, dan menu QR pelanggan (satu-satunya pembacanya) diam-diam jatuh
-- ke tarif hardcoded 11%/5% — menampilkan total yang berbeda dari yang dihitung
-- & disimpan server. Pembacanya sudah diperbaiki untuk memakai kunci yang benar;
-- kunci mati ini dibuang agar tak ada yang tergoda memakainya lagi.
--
-- `tax_inclusive` tetap ada & kini dipakai: menu pelanggan harus tahu apakah
-- harga sudah memuat pajak agar tidak menambahkannya lagi (lihat 114).

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
  -- Whitelist settings yang aman + diperlukan customer self-order.
  -- Nama kunci WAJIB sama dengan yang ditulis owner-panel & dibaca
  -- create_self_order — beda kunci = pelanggan dikutip harga yang salah.
  jsonb_build_object(
    'tax_active',              o.settings->'tax_active',
    'tax_percent',             o.settings->'tax_percent',
    'tax_name',                o.settings->'tax_name',
    'tax_inclusive',           o.settings->'tax_inclusive',
    'service_charge_percent',  o.settings->'service_charge_percent',
    'currency',                o.settings->'currency',
    'receipt_footer',          o.settings->'receipt_footer'
  ) AS settings,
  o.created_at,
  o.updated_at
FROM outlets o
WHERE o.is_active = true;

COMMENT ON VIEW v_outlets_public IS
  'Public-safe projection of outlets — hides loyalty_settings & payment_methods. '
  'settings hanya berisi field yang aman dibaca publik & diperlukan customer menu. '
  'tax_rate/service_rate (115) dibuang: tak pernah ditulis, selalu NULL.';

GRANT SELECT ON v_outlets_public TO anon, authenticated;

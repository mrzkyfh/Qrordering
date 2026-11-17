-- ============================================================
-- 036_outlets_public_add_tax_fields.sql
-- Update v_outlets_public: tambah tax fields yang dibutuhkan
-- customer self-order untuk hitung subtotal (tax, service charge).
--
-- BUG: customer-menu/app.js gagal load karena migration 033
-- revoke settings dari anon, tapi tax_active/tax_name/tax_percent/
-- service_charge_percent tidak ada di view.
-- ============================================================

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
  -- Whitelist settings yang aman + diperlukan customer self-order
  jsonb_build_object(
    'tax_active',              o.settings->'tax_active',
    'tax_percent',             o.settings->'tax_percent',
    'tax_name',                o.settings->'tax_name',
    'tax_inclusive',           o.settings->'tax_inclusive',
    'service_charge_percent',  o.settings->'service_charge_percent',
    'tax_rate',                o.settings->'tax_rate',
    'service_rate',            o.settings->'service_rate',
    'currency',                o.settings->'currency',
    'receipt_footer',          o.settings->'receipt_footer'
  ) AS settings,
  o.created_at,
  o.updated_at
FROM outlets o
WHERE o.is_active = true;

COMMENT ON VIEW v_outlets_public IS
  'Public-safe projection of outlets — hides loyalty_settings & payment_methods. '
  'settings hanya berisi field yang aman dibaca publik & diperlukan customer menu.';

GRANT SELECT ON v_outlets_public TO anon, authenticated;

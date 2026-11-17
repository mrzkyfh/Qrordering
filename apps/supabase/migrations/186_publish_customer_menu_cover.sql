-- 186_publish_customer_menu_cover.sql
--
-- Memublikasikan hanya URL foto sampul customer menu. Kunci settings lain
-- tetap tidak dapat dibaca pengguna anonim melalui v_outlets_public.

CREATE OR REPLACE FUNCTION public.sync_outlet_public_projection()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.outlets_public_projection WHERE id = OLD.id;
    RETURN OLD;
  END IF;

  IF NOT NEW.is_active THEN
    DELETE FROM public.outlets_public_projection WHERE id = NEW.id;
    RETURN NEW;
  END IF;

  v_settings := jsonb_build_object(
    'tax_percent',                    NEW.settings->'tax_percent',
    'tax_active',                     NEW.settings->'tax_active',
    'tax_name',                       NEW.settings->'tax_name',
    'tax_inclusive',                  NEW.settings->'tax_inclusive',
    'tax_calculation',                NEW.settings->'tax_calculation',
    'tax_order_types',                NEW.settings->'tax_order_types',
    'taxes',                          NEW.settings->'taxes',
    'service_charge_percent',         NEW.settings->'service_charge_percent',
    'currency',                       NEW.settings->'currency',
    'receipt_footer',                 NEW.settings->'receipt_footer',
    'rounding',                       NEW.settings->'rounding',
    'customer_menu_cover_url',        NEW.settings->'customer_menu_cover_url',
    'self_order_enabled',             COALESCE(NEW.settings->'self_order_enabled', 'true'::jsonb),
    'self_order_schedule_enabled',    COALESCE(NEW.settings->'self_order_schedule_enabled', 'false'::jsonb),
    'self_order_open_time',           COALESCE(NEW.settings->'self_order_open_time', to_jsonb('10:00'::text)),
    'self_order_close_time',          COALESCE(NEW.settings->'self_order_close_time', to_jsonb('22:00'::text)),
    'self_order_closed_message',      COALESCE(
      NEW.settings->'self_order_closed_message',
      to_jsonb('Order online sedang tutup. Silakan datang langsung.'::text)
    ),
    'self_order_require_name',        COALESCE(NEW.settings->'self_order_require_name', 'false'::jsonb),
    'self_order_allow_notes',         COALESCE(NEW.settings->'self_order_allow_notes', 'true'::jsonb),
    'self_order_max_active',          COALESCE(NEW.settings->'self_order_max_active', '15'::jsonb)
  );

  INSERT INTO public.outlets_public_projection (
    id, name, address, phone, city, logo_url, is_active, settings,
    created_at, updated_at
  )
  VALUES (
    NEW.id, NEW.name, NEW.address, NEW.phone, NEW.city, NEW.logo_url,
    NEW.is_active, v_settings, NEW.created_at, NEW.updated_at
  )
  ON CONFLICT (id) DO UPDATE SET
    name       = EXCLUDED.name,
    address    = EXCLUDED.address,
    phone      = EXCLUDED.phone,
    city       = EXCLUDED.city,
    logo_url   = EXCLUDED.logo_url,
    is_active  = EXCLUDED.is_active,
    settings   = EXCLUDED.settings,
    created_at = EXCLUDED.created_at,
    updated_at = EXCLUDED.updated_at;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_outlet_public_projection()
  FROM PUBLIC, anon, authenticated;

-- Sinkronkan nilai untuk outlet aktif yang sudah ada tanpa memublikasikan
-- seluruh JSON settings dari tabel outlets.
UPDATE public.outlets_public_projection AS projection
SET settings = jsonb_set(
  projection.settings,
  '{customer_menu_cover_url}',
  COALESCE(outlet.settings->'customer_menu_cover_url', 'null'::jsonb),
  TRUE
),
updated_at = outlet.updated_at
FROM public.outlets AS outlet
WHERE outlet.id = projection.id
  AND outlet.is_active;

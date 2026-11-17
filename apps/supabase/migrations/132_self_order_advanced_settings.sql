-- 132_self_order_advanced_settings.sql
-- Pengaturan Order Online lanjutan yang berlaku outlet-wide.
--
-- Migration 130 sudah memasang trigger self-order dasar. Di sini fungsi yang
-- sama diperluas supaya request langsung/API lama tetap tunduk pada setting
-- outlet, bukan hanya pada UI mobile.

UPDATE public.outlets
SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
  'self_order_schedule_enabled', COALESCE(settings->'self_order_schedule_enabled', 'false'::jsonb),
  'self_order_open_time', COALESCE(settings->'self_order_open_time', to_jsonb('10:00'::text)),
  'self_order_close_time', COALESCE(settings->'self_order_close_time', to_jsonb('22:00'::text)),
  'self_order_closed_message', COALESCE(settings->'self_order_closed_message', to_jsonb('Order online sedang tutup. Silakan datang langsung.'::text)),
  'self_order_require_name', COALESCE(settings->'self_order_require_name', 'false'::jsonb),
  'self_order_allow_notes', COALESCE(settings->'self_order_allow_notes', 'true'::jsonb),
  'self_order_auto_confirm', COALESCE(settings->'self_order_auto_confirm', 'false'::jsonb),
  'self_order_max_active', COALESCE(settings->'self_order_max_active', '15'::jsonb)
)
WHERE true;

CREATE OR REPLACE FUNCTION public.enforce_self_order_enabled()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_now TIME;
  v_open TIME;
  v_close TIME;
  v_enabled BOOLEAN;
  v_schedule BOOLEAN;
  v_require_name BOOLEAN;
  v_allow_notes BOOLEAN;
  v_auto_confirm BOOLEAN;
  v_max_active INTEGER;
  v_active INTEGER;
BEGIN
  IF NEW.order_type <> 'self_order' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(settings, '{}'::jsonb)
    INTO v_settings
  FROM public.outlets
  WHERE id = NEW.outlet_id;

  v_enabled := COALESCE((v_settings->>'self_order_enabled')::boolean, true);
  IF NOT v_enabled THEN
    RAISE EXCEPTION 'Pesanan online sedang ditutup'
      USING ERRCODE = '55000';
  END IF;

  v_schedule := COALESCE((v_settings->>'self_order_schedule_enabled')::boolean, false);
  IF v_schedule THEN
    -- Gunakan zona operasional aplikasi agar tidak bergantung pada timezone
    -- database/server.
    v_now := (now() AT TIME ZONE 'Asia/Jakarta')::time;
    v_open := CASE
      WHEN (v_settings->>'self_order_open_time') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        THEN (v_settings->>'self_order_open_time')::time
      ELSE TIME '10:00'
    END;
    v_close := CASE
      WHEN (v_settings->>'self_order_close_time') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        THEN (v_settings->>'self_order_close_time')::time
      ELSE TIME '22:00'
    END;

    IF v_open <> v_close AND NOT (
      CASE
        WHEN v_open < v_close THEN v_now >= v_open AND v_now < v_close
        ELSE v_now >= v_open OR v_now < v_close
      END
    ) THEN
      RAISE EXCEPTION '%', COALESCE(
        NULLIF(v_settings->>'self_order_closed_message', ''),
        'Order online sedang tutup. Silakan datang langsung.'
      ) USING ERRCODE = '55000';
    END IF;
  END IF;

  v_max_active := GREATEST(
    1,
    LEAST(
      CASE
        WHEN (v_settings->>'self_order_max_active') ~ '^[0-9]+$'
          THEN (v_settings->>'self_order_max_active')::integer
        ELSE 15
      END,
      15
    )
  );
  SELECT count(*)
    INTO v_active
  FROM public.orders
  WHERE outlet_id = NEW.outlet_id
    AND order_type = 'self_order'
    AND status NOT IN ('paid', 'cancelled', 'void');
  IF v_active >= v_max_active THEN
    RAISE EXCEPTION 'Outlet sedang mencapai batas order online aktif (%).', v_max_active
      USING ERRCODE = '55000';
  END IF;

  v_require_name := COALESCE((v_settings->>'self_order_require_name')::boolean, false);
  IF v_require_name AND NULLIF(btrim(NEW.customer_name), '') IS NULL THEN
    RAISE EXCEPTION 'Nama pelanggan wajib diisi untuk order online'
      USING ERRCODE = '22023';
  END IF;

  v_allow_notes := COALESCE((v_settings->>'self_order_allow_notes')::boolean, true);
  IF NOT v_allow_notes THEN
    NEW.notes := NULL;
  END IF;

  v_auto_confirm := COALESCE((v_settings->>'self_order_auto_confirm')::boolean, false);
  IF v_auto_confirm THEN
    NEW.status := 'confirmed';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_self_order_enabled ON public.orders;
CREATE TRIGGER trg_enforce_self_order_enabled
  BEFORE INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_self_order_enabled();

REVOKE ALL ON FUNCTION public.enforce_self_order_enabled() FROM PUBLIC;

-- Pertahankan projection pajak/service/rounding dari migration 131 dan tambah
-- hanya setting publik yang diperlukan halaman customer menu.
CREATE OR REPLACE VIEW public.v_outlets_public AS
SELECT
  o.id,
  o.name,
  o.address,
  o.phone,
  o.city,
  o.logo_url,
  o.is_active,
  jsonb_build_object(
    'tax_percent',             o.settings->'tax_percent',
    'tax_active',              o.settings->'tax_active',
    'tax_name',                o.settings->'tax_name',
    'tax_inclusive',           o.settings->'tax_inclusive',
    'tax_calculation',         o.settings->'tax_calculation',
    'tax_order_types',         o.settings->'tax_order_types',
    'taxes',                   o.settings->'taxes',
    'service_charge_percent',  o.settings->'service_charge_percent',
    'currency',                o.settings->'currency',
    'receipt_footer',          o.settings->'receipt_footer',
    'rounding',                o.settings->'rounding',
    'self_order_enabled',      COALESCE(o.settings->'self_order_enabled', 'true'::jsonb),
    'self_order_schedule_enabled', COALESCE(o.settings->'self_order_schedule_enabled', 'false'::jsonb),
    'self_order_open_time',     COALESCE(o.settings->'self_order_open_time', to_jsonb('10:00'::text)),
    'self_order_close_time',    COALESCE(o.settings->'self_order_close_time', to_jsonb('22:00'::text)),
    'self_order_closed_message', COALESCE(o.settings->'self_order_closed_message', to_jsonb('Order online sedang tutup. Silakan datang langsung.'::text)),
    'self_order_require_name',  COALESCE(o.settings->'self_order_require_name', 'false'::jsonb),
    'self_order_allow_notes',   COALESCE(o.settings->'self_order_allow_notes', 'true'::jsonb),
    'self_order_max_active',    COALESCE(o.settings->'self_order_max_active', '15'::jsonb)
  ) AS settings,
  o.created_at,
  o.updated_at
FROM public.outlets o
WHERE o.is_active = true;

GRANT SELECT ON public.v_outlets_public TO anon, authenticated;

COMMENT ON VIEW public.v_outlets_public IS
  'Public-safe outlet projection for customer menu: tax, service, rounding, '
  'and self-order availability/settings only.';

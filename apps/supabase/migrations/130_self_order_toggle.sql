-- 130_self_order_toggle.sql
-- Pengaturan Order Online harus bersifat global per outlet, bukan preferensi
-- lokal perangkat. Nilai default tetap aktif agar outlet lama tidak berubah
-- perilakunya ketika migration ini dipasang.

UPDATE public.outlets
SET settings = COALESCE(settings, '{}'::jsonb) || '{"self_order_enabled": true}'::jsonb
WHERE NOT (COALESCE(settings, '{}'::jsonb) ? 'self_order_enabled');

-- Pengaman terakhir di database. UI/customer menu boleh memberi pengalaman
-- "ditutup", tetapi order anonim tetap harus ditolak jika request dibuat
-- langsung atau memakai aplikasi versi lama.
CREATE OR REPLACE FUNCTION public.enforce_self_order_enabled()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_enabled BOOLEAN;
BEGIN
  IF NEW.order_type <> 'self_order' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE((settings->>'self_order_enabled')::boolean, true)
    INTO v_enabled
  FROM public.outlets
  WHERE id = NEW.outlet_id;

  IF NOT COALESCE(v_enabled, true) THEN
    RAISE EXCEPTION 'Pesanan online sedang ditutup'
      USING ERRCODE = '55000';
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

-- Tambahkan hanya satu kunci ke projection publik yang memang sudah dipakai
-- customer menu. Kunci lain di settings tetap tidak ikut terekspos.
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
    'tax_active',              o.settings->'tax_active',
    'tax_percent',             o.settings->'tax_percent',
    'tax_name',                o.settings->'tax_name',
    'tax_inclusive',           o.settings->'tax_inclusive',
    'service_charge_percent',  o.settings->'service_charge_percent',
    'currency',                o.settings->'currency',
    'receipt_footer',          o.settings->'receipt_footer',
    'self_order_enabled',      COALESCE(o.settings->'self_order_enabled', 'true'::jsonb)
  ) AS settings,
  o.created_at,
  o.updated_at
FROM public.outlets o
WHERE o.is_active = true;

COMMENT ON VIEW public.v_outlets_public IS
  'Public-safe projection of outlets. self_order_enabled dipakai customer menu; '
  'field internal lain tetap tidak diekspos.';

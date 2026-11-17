-- 219_fix_device_bootstrap_service_role_detection.sql
--
-- Migration 218 membaca claim service-role lewat nama GUC lama yang tidak
-- selalu diisi PostgREST. Gunakan auth.role(), sumber kanonik Supabase, agar
-- pengecualian bootstrap tetap sempit tetapi benar-benar dapat dipakai oleh
-- Edge Function create-staff.

CREATE OR REPLACE FUNCTION public.guard_device_role_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_jwt_role TEXT := COALESCE(auth.role(), '');
BEGIN
  IF (OLD.role = 'pelanggan') IS NOT DISTINCT FROM
     (NEW.role = 'pelanggan') THEN
    RETURN NEW;
  END IF;

  IF v_jwt_role = 'service_role'
     AND OLD.role = 'kasir'
     AND NEW.role = 'pelanggan'
     AND EXISTS (
       SELECT 1
       FROM auth.users u
       WHERE u.id = NEW.id
         AND u.raw_user_meta_data->>'role' = 'pelanggan'
         AND u.created_at >= now() - interval '5 minutes'
     ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'Role akun perangkat tidak dapat diubah melalui pengelolaan staf umum'
    USING ERRCODE = '42501';
END;
$$;

REVOKE ALL ON FUNCTION public.guard_device_role_transition()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.guard_device_role_transition() IS
  'Blok transisi role perangkat; bootstrap kasir ke pelanggan hanya untuk service-role dan akun Auth baru.';

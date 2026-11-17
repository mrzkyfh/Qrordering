-- 218_allow_secure_device_profile_bootstrap.sql
--
-- handle_new_user selalu membuat profil awal sebagai `kasir` agar metadata
-- signup publik tidak dapat melakukan privilege escalation. create-staff lalu
-- melengkapi role final dengan service-role. Migration 217 sebelumnya menolak
-- transisi bootstrap kasir -> pelanggan tersebut tanpa pengecualian.
--
-- Pengecualian di bawah sengaja sangat sempit: JWT harus service_role, target
-- harus akun Auth berusia maksimal lima menit, dan metadata Auth yang dibuat
-- server harus sudah meminta role pelanggan. Request authenticated/anon tetap
-- tidak dapat mengubah staf menjadi perangkat atau sebaliknya.

CREATE OR REPLACE FUNCTION public.guard_device_role_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_jwt_role TEXT := current_setting('request.jwt.claim.role', true);
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
  'Blok transisi role perangkat, kecuali bootstrap kasir ke pelanggan oleh service-role untuk akun Auth baru.';

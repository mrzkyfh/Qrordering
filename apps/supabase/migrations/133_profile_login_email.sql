-- 133_profile_login_email.sql
-- Simpan email login non-rahasia di profiles agar owner dapat mengidentifikasi
-- akun perangkat per cabang tanpa membuka auth.users dari client.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS login_email TEXT;

COMMENT ON COLUMN public.profiles.login_email IS
  'Email login akun web/perangkat. Password tidak pernah disimpan di profiles.';

-- Backfill akun lama. Email sintetis internal staff tidak ditampilkan sebagai
-- email login karena akun tersebut memang hanya memakai PIN.
UPDATE public.profiles p
SET login_email = CASE
  WHEN u.email IS NOT NULL AND u.email NOT LIKE '%@pos.local' THEN u.email
  ELSE NULL
END
FROM auth.users u
WHERE u.id = p.id
  AND p.login_email IS NULL;

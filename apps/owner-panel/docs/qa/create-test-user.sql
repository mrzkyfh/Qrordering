-- ============================================================
-- CREATE QA TEST USER — Owner Panel
-- Paste ke Supabase SQL Editor dan jalankan
--
-- Credentials hasil:
--   Email   : test-qa@time420s.com
--   Password: QATest123!
--   Role    : owner (bisa menjalankan smoke test owner + admin)
-- ============================================================

DO $$
DECLARE
  v_user_id   uuid;
  v_outlet_id uuid;
BEGIN

  -- Ambil outlet pertama yang aktif
  SELECT id INTO v_outlet_id
  FROM outlets
  WHERE is_active = true
  ORDER BY created_at
  LIMIT 1;

  -- Cek apakah user sudah ada
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = 'test-qa@time420s.com';

  IF v_user_id IS NOT NULL THEN
    -- User sudah ada — reset password & pastikan profile benar
    RAISE NOTICE 'User sudah ada (id: %), update password + profile...', v_user_id;

    UPDATE auth.users
    SET encrypted_password = crypt('QATest123!', gen_salt('bf')),
        email_confirmed_at = COALESCE(email_confirmed_at, now()),
        updated_at = now()
    WHERE id = v_user_id;

    INSERT INTO profiles (id, outlet_id, role, full_name, phone, is_active, created_at, updated_at)
    VALUES (v_user_id, v_outlet_id, 'owner', 'QA Tester', null, true, now(), now())
    ON CONFLICT (id) DO UPDATE
      SET role = 'owner', outlet_id = v_outlet_id, is_active = true, updated_at = now();

  ELSE
    -- User belum ada — buat baru
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      is_super_admin, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id, 'authenticated', 'authenticated',
      'test-qa@time420s.com',
      crypt('QATest123!', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"QA Tester"}'::jsonb,
      false, now(), now(), '', '', '', ''
    );

    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(), v_user_id,
      'test-qa@time420s.com',
      jsonb_build_object('sub', v_user_id::text, 'email', 'test-qa@time420s.com'),
      'email', now(), now(), now()
    );

    INSERT INTO profiles (id, outlet_id, role, full_name, phone, is_active, created_at, updated_at)
    VALUES (v_user_id, v_outlet_id, 'owner', 'QA Tester', null, true, now(), now())
    ON CONFLICT (id) DO UPDATE
      SET role = 'owner', outlet_id = v_outlet_id, full_name = 'QA Tester',
          is_active = true, updated_at = now();

    RAISE NOTICE 'QA user dibuat — id: %, outlet: %', v_user_id, v_outlet_id;
  END IF;

END;
$$;


-- ============================================================
-- VERIFIKASI — jalankan ini setelah script di atas berhasil
-- ============================================================
SELECT
  u.email,
  p.full_name,
  p.role,
  o.name AS outlet,
  u.email_confirmed_at IS NOT NULL AS email_confirmed
FROM auth.users u
JOIN profiles p ON p.id = u.id
LEFT JOIN outlets o ON o.id = p.outlet_id
WHERE u.email = 'test-qa@time420s.com';


-- ============================================================
-- CLEANUP — jalankan saat user test sudah tidak dibutuhkan
-- ============================================================
/*
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM auth.users WHERE email = 'test-qa@time420s.com';
  IF v_id IS NULL THEN RAISE NOTICE 'User tidak ditemukan'; RETURN; END IF;
  DELETE FROM auth.identities WHERE user_id = v_id;
  DELETE FROM profiles         WHERE id = v_id;
  DELETE FROM auth.users       WHERE id = v_id;
  RAISE NOTICE 'QA user dihapus: %', v_id;
END;
$$;
*/

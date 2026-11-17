-- Hapus akun QA sementara yang dipakai automated owner-panel tests.
DO $$
DECLARE
  v_id UUID;
BEGIN
  SELECT id INTO v_id FROM auth.users WHERE email = 'test-qa@time420s.com';
  IF v_id IS NULL THEN RETURN; END IF;
  DELETE FROM auth.identities WHERE user_id = v_id;
  DELETE FROM public.profiles WHERE id = v_id;
  DELETE FROM auth.users WHERE id = v_id;
END;
$$;

SELECT
  (SELECT count(*) FROM auth.users WHERE email = 'test-qa@time420s.com') AS auth_qa_users,
  (SELECT count(*) FROM public.profiles WHERE full_name = 'QA Tester') AS qa_profiles;

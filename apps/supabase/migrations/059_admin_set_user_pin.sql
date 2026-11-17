-- ============================================================
-- 059_admin_set_user_pin.sql
-- Owner/admin menetapkan (set/reset) PIN staff dari owner panel.
--
-- - SECURITY DEFINER: hash PIN ditulis ke profiles.pin_hash user target.
-- - Hanya pemanggil role 'owner' atau 'admin'.
-- - Admin hanya boleh untuk staf di outlet yang sama; owner bebas.
-- - pin_hash tidak pernah dikembalikan ke client.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION admin_set_user_pin(p_user_id UUID, p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   TEXT;
  v_caller_outlet UUID;
  v_target_outlet UUID;
  v_target_exists BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi';
  END IF;

  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM profiles WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'owner' AND v_caller_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Hanya owner/admin yang boleh mengatur PIN staf';
  END IF;

  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN harus 4-6 digit angka';
  END IF;

  SELECT outlet_id, TRUE INTO v_target_outlet, v_target_exists
  FROM profiles WHERE id = p_user_id;

  IF v_target_exists IS NULL THEN
    RAISE EXCEPTION 'User tidak ditemukan';
  END IF;

  -- Admin dibatasi ke outlet sendiri; owner bebas lintas-outlet.
  IF v_caller_role = 'admin' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Admin hanya boleh mengatur PIN staf di outlet yang sama';
  END IF;

  UPDATE profiles
  SET pin_hash = crypt(p_pin, gen_salt('bf')),
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_set_user_pin(UUID, TEXT) TO authenticated;

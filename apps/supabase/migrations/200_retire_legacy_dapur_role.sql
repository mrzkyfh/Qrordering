-- 200_retire_legacy_dapur_role.sql
--
-- Role akun dapur sudah tidak menjadi bagian dari aplikasi. Fitur printer,
-- tiket, dan routing stasiun dapur tetap dipertahankan dan tidak bergantung
-- pada enum user_role.
--
-- PostgreSQL versi yang digunakan proyek ini tidak menyediakan DROP VALUE
-- untuk enum. Karena itu label lama dinetralkan, seluruh data dikonversi ke
-- kasir, lalu CHECK constraint mencegah nilai peninggalan dipakai kembali.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'user_role'
      AND e.enumlabel = 'dapur'
  ) THEN
    UPDATE public.profiles
    SET role = 'kasir', updated_at = now()
    WHERE role = 'dapur';

    UPDATE public.commission_rules
    SET role = 'kasir'
    WHERE role = 'dapur';

    ALTER TYPE public.user_role RENAME VALUE 'dapur' TO '_removed_role';
  END IF;
END
$$;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_supported_role_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_supported_role_check
  CHECK (role::text <> '_removed_role');

ALTER TABLE public.commission_rules
  DROP CONSTRAINT IF EXISTS commission_rules_supported_role_check;
ALTER TABLE public.commission_rules
  ADD CONSTRAINT commission_rules_supported_role_check
  CHECK (role IS NULL OR role::text <> '_removed_role');

CREATE OR REPLACE FUNCTION public.role_rank(p_role public.user_role)
RETURNS INT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE p_role
    WHEN 'owner'   THEN 4
    WHEN 'admin'   THEN 3
    WHEN 'manajer' THEN 3
    WHEN 'kasir'   THEN 1
    ELSE 0
  END
$$;

COMMENT ON FUNCTION public.role_rank(public.user_role) IS
  'Hierarki role aktif: owner 4; admin/manajer 3; kasir 1; akun perangkat 0.';

CREATE OR REPLACE FUNCTION public.delete_outlet_cascade(p_outlet_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_staff_ids UUID[];
  v_staff_deleted INT := 0;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'Hanya owner yang boleh menghapus cabang';
  END IF;

  SELECT array_agg(id) INTO v_staff_ids
  FROM public.profiles
  WHERE outlet_id = p_outlet_id
    AND role = 'kasir';

  DELETE FROM public.outlets WHERE id = p_outlet_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF v_staff_ids IS NOT NULL AND array_length(v_staff_ids, 1) > 0 THEN
    WITH del AS (
      DELETE FROM auth.users WHERE id = ANY (v_staff_ids) RETURNING id
    )
    SELECT count(*) INTO v_staff_deleted FROM del;
  END IF;

  RETURN jsonb_build_object(
    'status', 'deleted',
    'staff_deleted', v_staff_deleted
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_outlet_cascade(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_outlet_cascade(UUID) TO authenticated;

COMMENT ON FUNCTION public.delete_outlet_cascade(UUID) IS
  'Hapus cabang, seluruh data transaksinya, dan akun kasir milik cabang. '
  'Owner, admin, dan manajer tidak ikut dihapus. Hanya owner.';

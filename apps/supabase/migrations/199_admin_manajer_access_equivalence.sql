-- 199_admin_manajer_access_equivalence.sql
--
-- Manajer memiliki batas akses, rank, dan scope outlet yang sama dengan admin.
-- auth_role() menormalkan manajer menjadi admin agar seluruh policy/RPC lama yang
-- memakai helper pusat otomatis memperoleh perilaku yang sama. Dua RPC profil
-- di bawah membaca profiles.role secara langsung, sehingga definisinya juga
-- diperbarui secara eksplisit.

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

CREATE OR REPLACE FUNCTION public.auth_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT CASE
    WHEN role = 'manajer' THEN 'admin'::public.user_role
    ELSE role
  END
  FROM public.profiles
  WHERE id = auth.uid() AND is_active
$$;

CREATE OR REPLACE FUNCTION public.auth_rank()
RETURNS INT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.role_rank(role)
  FROM public.profiles
  WHERE id = auth.uid() AND is_active
$$;

COMMENT ON FUNCTION public.auth_role() IS
  'Peran otorisasi pemanggil aktif. Manajer dinormalkan menjadi admin agar seluruh '
  'policy dan RPC memberi keduanya hak akses yang identik.';
COMMENT ON FUNCTION public.role_rank(public.user_role) IS
  'Hierarki role: owner 4; admin/manajer 3; kasir 1; akun perangkat 0.';

CREATE OR REPLACE FUNCTION public.update_staff_profile(
  p_target UUID,
  p_patch JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   public.user_role;
  v_caller_outlet UUID;
  v_target_role   public.user_role;
  v_target_outlet UUID;
  v_new_role      public.user_role;
  v_new_outlet    UUID;
  v_new_name      TEXT;
  v_new_phone     TEXT;
  v_new_active    BOOLEAN;
  v_new_refund    BOOLEAN;
  v_keys          TEXT[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi' USING ERRCODE = '42501';
  END IF;
  IF p_target IS NULL OR p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'Target dan perubahan profil wajib diisi'
      USING ERRCODE = '22023';
  END IF;

  SELECT role, outlet_id
    INTO v_caller_role, v_caller_outlet
  FROM public.profiles
  WHERE id = auth.uid() AND is_active
    AND role IN ('owner', 'admin', 'manajer');

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Hanya owner/admin/manajer aktif yang dapat mengubah profil staf'
      USING ERRCODE = '42501';
  END IF;

  SELECT role, outlet_id, full_name, phone, is_active, can_refund
    INTO v_target_role, v_target_outlet, v_new_name, v_new_phone,
         v_new_active, v_new_refund
  FROM public.profiles
  WHERE id = p_target;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Staff tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(k) INTO v_keys
  FROM jsonb_object_keys(p_patch) AS keys(k);
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(v_keys, ARRAY[]::TEXT[])) AS k
    WHERE k NOT IN ('full_name', 'role', 'outlet_id', 'phone', 'is_active', 'can_refund')
  ) THEN
    RAISE EXCEPTION 'Field profil tidak diizinkan' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role <> 'owner' THEN
    IF v_target_outlet IS DISTINCT FROM v_caller_outlet
       OR public.role_rank(v_target_role) >= public.role_rank(v_caller_role) THEN
      RAISE EXCEPTION 'Tidak berwenang mengubah profil staf ini'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF v_target_role = 'owner' AND p_target <> auth.uid() THEN
    RAISE EXCEPTION 'Profil owner lain dilindungi' USING ERRCODE = '42501';
  END IF;
  IF p_target = auth.uid()
     AND (p_patch ? 'role' OR p_patch ? 'outlet_id' OR p_patch ? 'is_active') THEN
    RAISE EXCEPTION 'Role, outlet, dan status akun sendiri tidak dapat diubah'
      USING ERRCODE = '42501';
  END IF;

  v_new_role := v_target_role;
  IF p_patch ? 'role' THEN
    IF jsonb_typeof(p_patch->'role') <> 'string' THEN
      RAISE EXCEPTION 'Role tidak valid' USING ERRCODE = '22023';
    END IF;
    v_new_role := (p_patch->>'role')::public.user_role;
  END IF;

  IF v_new_role = 'owner' AND v_target_role <> 'owner' THEN
    RAISE EXCEPTION 'Promosi menjadi owner harus dilakukan di level sistem'
      USING ERRCODE = '42501';
  END IF;
  IF v_caller_role <> 'owner'
     AND public.role_rank(v_new_role) >= public.role_rank(v_caller_role) THEN
    RAISE EXCEPTION 'Tidak boleh mengatur role setara atau lebih tinggi'
      USING ERRCODE = '42501';
  END IF;

  IF p_patch ? 'outlet_id' THEN
    v_new_outlet := CASE
      WHEN p_patch->'outlet_id' = 'null'::jsonb THEN NULL
      ELSE (p_patch->>'outlet_id')::UUID
    END;
  ELSE
    v_new_outlet := v_target_outlet;
  END IF;

  IF v_new_role <> 'owner' AND v_new_outlet IS NULL THEN
    RAISE EXCEPTION 'Staff non-owner wajib memiliki outlet'
      USING ERRCODE = '22023';
  END IF;
  IF v_new_outlet IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.outlets WHERE id = v_new_outlet AND is_active
  ) THEN
    RAISE EXCEPTION 'Outlet tidak aktif atau tidak ditemukan'
      USING ERRCODE = '22023';
  END IF;
  IF v_caller_role <> 'owner' AND v_new_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Admin/manajer hanya boleh memindahkan staf di outlet sendiri'
      USING ERRCODE = '42501';
  END IF;

  IF p_patch ? 'full_name' THEN
    v_new_name := NULLIF(btrim(p_patch->>'full_name'), '');
    IF v_new_name IS NULL THEN
      RAISE EXCEPTION 'Nama staf wajib diisi' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_patch ? 'phone' THEN
    v_new_phone := p_patch->>'phone';
  END IF;
  IF p_patch ? 'is_active' THEN
    v_new_active := (p_patch->>'is_active')::BOOLEAN;
    IF p_target = auth.uid() AND NOT v_new_active THEN
      RAISE EXCEPTION 'Akun sendiri tidak dapat dinonaktifkan'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  IF p_patch ? 'can_refund' THEN
    v_new_refund := (p_patch->>'can_refund')::BOOLEAN;
  END IF;

  PERFORM set_config('app.staff_profile_update', '1', true);
  UPDATE public.profiles
  SET full_name  = v_new_name,
      role       = v_new_role,
      outlet_id  = v_new_outlet,
      phone      = v_new_phone,
      is_active  = v_new_active,
      can_refund = v_new_refund,
      updated_at = NOW()
  WHERE id = p_target;
END;
$$;

REVOKE ALL ON FUNCTION public.update_staff_profile(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_staff_profile(UUID, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_staff_user(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auth, public
AS $$
DECLARE
  v_caller_role   public.user_role;
  v_caller_outlet UUID;
  v_target_role   public.user_role;
  v_target_outlet UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi' USING ERRCODE = '42501';
  END IF;

  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM public.profiles
  WHERE id = auth.uid() AND is_active
    AND role IN ('owner', 'admin', 'manajer');
  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Hanya owner/admin/manajer aktif yang dapat menghapus staf'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Tidak bisa menghapus akun sendiri' USING ERRCODE = '42501';
  END IF;

  SELECT role, outlet_id INTO v_target_role, v_target_outlet
  FROM public.profiles WHERE id = p_user_id;
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Akun owner tidak dapat dihapus lewat panel'
      USING ERRCODE = '42501';
  END IF;

  IF public.role_rank(v_caller_role) <= public.role_rank(v_target_role) THEN
    RAISE EXCEPTION 'Tidak berwenang menghapus staf level sama atau lebih tinggi'
      USING ERRCODE = '42501';
  END IF;

  IF v_caller_role <> 'owner'
     AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Hanya boleh menghapus staf di outlet Anda sendiri'
      USING ERRCODE = '42501';
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_staff_user(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_staff_user(UUID) TO authenticated;

COMMENT ON FUNCTION public.update_staff_profile(UUID, JSONB) IS
  'Owner dapat mengelola lintas outlet; admin dan manajer memiliki wewenang identik '
  'untuk staf berlevel lebih rendah di outlet sendiri.';
COMMENT ON FUNCTION public.delete_staff_user(UUID) IS
  'Hapus staf permanen dengan admin dan manajer sebagai role setara, tetap dibatasi '
  'rank, outlet, status aktif, dan perlindungan akun owner.';

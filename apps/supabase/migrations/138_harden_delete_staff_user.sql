-- 138_harden_delete_staff_user.sql
-- delete_staff_user (030) jauh lebih lemah dari jalur yang seharusnya.
--
-- ══ MASALAH ═════════════════════════════════════════════════════════════════
--
-- owner-panel MENGHAPUS staf lewat RPC delete_staff_user (useStaff.ts), BUKAN
-- lewat edge function delete-staff (yang punya penjaga rank + outlet + is_active).
-- Edge function-nya kini tak dipanggil siapa pun, sedangkan RPC 030 hanya cek:
--   • caller owner ATAU admin
--   • bukan diri sendiri
-- dan TIDAK memeriksa hierarki, outlet, maupun is_active. Akibatnya, lewat REST:
--   • ADMIN bisa menghapus akun OWNER (eskalasi hak — fatal),
--   • admin bisa menghapus staf OUTLET LAIN (lintas-tenant),
--   • admin/owner yang baru DINONAKTIFKAN masih bisa menghapus (sesi hidup).
--
-- ══ PERBAIKAN ═══════════════════════════════════════════════════════════════
--
-- Samakan dengan hierarki update_staff_profile (136) & edge function:
--   1. Caller wajib owner/admin AKTIF (is_active).
--   2. Tak boleh hapus diri sendiri (dipertahankan).
--   3. Akun owner DILINDUNGI — tak bisa dihapus lewat panel (level sistem).
--   4. Rank: hanya boleh menghapus level DI BAWAH sendiri
--      (role_rank(caller) > role_rank(target)).
--   5. Non-owner: target wajib di outlet yang sama.
--
-- SECURITY DEFINER dipertahankan (hapus dari auth.users → cascade profiles).
-- search_path tetap 'auth, public' seperti 030 karena fungsi menyentuh auth.users.

CREATE OR REPLACE FUNCTION delete_staff_user(p_user_id UUID)
RETURNS void
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

  -- Caller wajib owner/admin AKTIF (◄ 138: + is_active, sebelumnya tak dicek).
  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM public.profiles
  WHERE id = auth.uid() AND is_active AND role IN ('owner', 'admin');
  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Hanya owner/admin aktif yang dapat menghapus staf'
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

  -- ◄ 138: akun owner dilindungi (tak bisa dihapus lewat panel).
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Akun owner tidak dapat dihapus lewat panel'
      USING ERRCODE = '42501';
  END IF;

  -- ◄ 138: hierarki — hanya boleh menghapus level DI BAWAH sendiri.
  IF role_rank(v_caller_role) <= role_rank(v_target_role) THEN
    RAISE EXCEPTION 'Tidak berwenang menghapus staf level sama atau lebih tinggi'
      USING ERRCODE = '42501';
  END IF;

  -- ◄ 138: non-owner hanya boleh menghapus staf di outletnya sendiri.
  IF v_caller_role <> 'owner' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Hanya boleh menghapus staf di outlet Anda sendiri'
      USING ERRCODE = '42501';
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION delete_staff_user(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION delete_staff_user(UUID) TO authenticated;

COMMENT ON FUNCTION delete_staff_user(UUID) IS
  'Hapus staf permanen. Wewenang setara update_staff_profile (136): owner/admin '
  'AKTIF, hierarki rank, scoping outlet non-owner, akun owner dilindungi (138). '
  'Sebelumnya hanya cek owner/admin tanpa rank/outlet/is_active.';

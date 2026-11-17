-- 122_deactivated_staff_lose_access.sql
-- "Nonaktifkan staf" selama ini KOSMETIK — akses tetap penuh.
--
-- MASALAH. Owner-panel menampilkan status Aktif/Nonaktif dan bisa menulis
-- profiles.is_active. Tapi TIDAK ADA satu pun policy RLS yang memeriksanya, dan
-- ketiga helper yang menjadi fondasi semua policy —
--     auth_role()      : SELECT role      FROM profiles WHERE id = auth.uid()
--     auth_outlet_id() : SELECT outlet_id FROM profiles WHERE id = auth.uid()
--     is_owner()       : SELECT role='owner' FROM profiles WHERE id = auth.uid()
-- — tidak menyaring is_active sama sekali.
--
-- Akibatnya: staf yang dinonaktifkan tetap punya akses PENUH selama sesinya
-- hidup. Ia masih bisa membuka order, void, tutup shift, membaca seluruh data
-- outlet. Owner mengira aksesnya sudah dicabut; kenyataannya tidak. Satu-satunya
-- tempat is_active benar-benar ditegakkan adalah _find_approver (070) — jadi
-- staf nonaktif tak bisa menyetujui void, tapi bisa melakukan segalanya yang
-- lain. Inkonsistensi ini yang membuatnya lolos: sekilas is_active "dipakai".
--
-- Perbaikan di helper, bukan di tiap policy: satu perubahan menutup seluruh
-- permukaan sekaligus, dan tak ada policy yang bisa lupa memeriksanya.
--
-- Untuk staf nonaktif ketiga fungsi kini mengembalikan NULL. Policy berbentuk
-- `USING (is_owner() OR outlet_id = auth_outlet_id())` menjadi NULL → RLS
-- menolak (hanya TRUE yang mengizinkan). Default-nya aman: tertutup.
--
-- TIDAK mengunci siapa pun secara tak sengaja: profiles.is_active NOT NULL
-- DEFAULT TRUE dan handle_new_user tak menyentuhnya — hanya yang SENGAJA
-- dinonaktifkan yang terdampak, persis maksudnya.
--
-- Staf nonaktif tetap bisa membaca profilnya sendiri: policy profiles_select
-- punya cabang `OR id = auth.uid()` yang tak lewat helper ini. Jadi aplikasi
-- masih bisa menampilkan "akun dinonaktifkan", bukan error tak jelas.
--
-- `SET search_path` WAJIB ditulis ulang: 061 mengeraskannya lewat ALTER FUNCTION,
-- dan CREATE OR REPLACE tanpa klausa ini akan menghapus hardening itu diam-diam.

CREATE OR REPLACE FUNCTION auth_role()
RETURNS user_role LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
  SELECT role FROM profiles WHERE id = auth.uid() AND is_active
$$;

CREATE OR REPLACE FUNCTION auth_outlet_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
  SELECT outlet_id FROM profiles WHERE id = auth.uid() AND is_active
$$;

CREATE OR REPLACE FUNCTION is_owner()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
  SELECT role = 'owner' FROM profiles WHERE id = auth.uid() AND is_active
$$;

CREATE OR REPLACE FUNCTION auth_rank()
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT role_rank(role) FROM profiles WHERE id = auth.uid() AND is_active
$$;

COMMENT ON FUNCTION auth_role() IS
  'Peran pemanggil, atau NULL bila akunnya dinonaktifkan. Fondasi seluruh RLS — '
  'is_active ditegakkan di sini agar tak ada policy yang bisa lupa memeriksanya.';
COMMENT ON FUNCTION auth_outlet_id() IS
  'Outlet pemanggil, atau NULL bila akunnya dinonaktifkan.';
COMMENT ON FUNCTION is_owner() IS
  'TRUE hanya untuk owner yang AKTIF. Nonaktif → NULL → RLS menolak.';

-- Grant dipertahankan persis seperti 069 + 082 (anon perlu EXECUTE agar policy
-- bertarget public tidak melempar 42501 saat dievaluasi untuk pelanggan QR).
REVOKE EXECUTE ON FUNCTION auth_role()      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auth_outlet_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION is_owner()       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auth_rank()      FROM PUBLIC;

GRANT EXECUTE ON FUNCTION auth_role()      TO authenticated, anon;
GRANT EXECUTE ON FUNCTION auth_outlet_id() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION is_owner()       TO authenticated, anon;
GRANT EXECUTE ON FUNCTION auth_rank()      TO authenticated, anon;

-- ── Edge function & RPC pembuat akun juga harus menolak staf nonaktif ────────
-- create-staff/delete-staff membaca profiles langsung (role, outlet_id) tanpa
-- memeriksa is_active — sehingga admin nonaktif masih bisa membuat/menghapus
-- akun. Ditutup di lapisan DB agar berlaku untuk jalur mana pun.
CREATE OR REPLACE FUNCTION set_staff_pin(p_target UUID, p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   user_role;
  v_caller_outlet UUID;
  v_target_role   user_role;
  v_target_outlet UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi';
  END IF;

  -- ◄ 122: AND is_active — akun nonaktif tak boleh lagi mengatur PIN siapa pun.
  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM profiles WHERE id = auth.uid() AND is_active;
  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Akun Anda tidak aktif' USING ERRCODE = '42501';
  END IF;

  SELECT role, outlet_id INTO v_target_role, v_target_outlet
  FROM profiles WHERE id = p_target;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Staff tidak ditemukan';
  END IF;

  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN harus 4-6 digit angka';
  END IF;

  -- Hierarki: hanya boleh atur PIN untuk level sendiri ke bawah.
  IF role_rank(v_caller_role) < role_rank(v_target_role) THEN
    RAISE EXCEPTION 'Tidak berwenang mengatur PIN role di atas Anda';
  END IF;

  -- Selain owner: target wajib di outlet yang sama.
  IF v_caller_role <> 'owner' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Hanya boleh mengatur PIN staf di outlet yang sama';
  END IF;

  UPDATE profiles
  SET pin_hash = crypt(p_pin, gen_salt('bf')),
      updated_at = NOW()
  WHERE id = p_target;
END;
$$;

REVOKE EXECUTE ON FUNCTION set_staff_pin(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION set_staff_pin(UUID, TEXT) TO authenticated;

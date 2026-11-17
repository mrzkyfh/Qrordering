-- ============================================================
-- 066_clockin_device_gate.sql
-- Gerbang keamanan clock-in: daftar staff hanya bisa diakses setelah perangkat
-- login akun cabang (authenticated), bukan anon. Menutup kebocoran daftar
-- staff/cabang & mempersempit brute-force PIN dari publik (Play Store).
--
-- Akun perangkat = profil role 'pelanggan' + outlet_id cabang (otomatis
-- tersembunyi dari picker karena role 'pelanggan' di-exclude).
-- ============================================================

-- list_clockin_staff: wajib authenticated & outlet pemanggil = p_outlet
-- (kecuali owner). Anon dicabut.
CREATE OR REPLACE FUNCTION list_clockin_staff(p_outlet UUID)
RETURNS TABLE(id UUID, full_name TEXT, role user_role, has_pin BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, full_name, role, (pin_hash IS NOT NULL)
  FROM profiles
  WHERE is_active
    AND role <> 'pelanggan'
    AND (outlet_id = p_outlet OR role = 'owner')
    -- Gerbang: pemanggil harus perangkat/staff outlet itu (atau owner).
    AND (is_owner() OR p_outlet = auth_outlet_id())
  ORDER BY role_rank(role) DESC, full_name
$$;

REVOKE EXECUTE ON FUNCTION list_clockin_staff(UUID) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION list_clockin_staff(UUID) TO authenticated;

-- ============================================================
-- 051_delete_outlet_cascade_rpc.sql
-- RPC hapus cabang + semua data terkait + akun staff cabang.
--
-- Alur (atomik, dalam 1 transaksi fungsi):
--   1. Pastikan pemanggil adalah owner.
--   2. TANGKAP dulu id staff Kasir/Dapur milik cabang ini (sebelum
--      outlet dihapus, karena profiles.outlet_id = ON DELETE SET NULL
--      akan menghilangkan kaitannya).
--   3. Hapus outlet → cascade ke seluruh data transaksi (lihat 050),
--      termasuk shifts. Ini WAJIB sebelum hapus staff: shifts.kasir_id
--      ber-NO ACTION ke profiles, jadi shift harus lenyap dulu agar
--      penghapusan akun staff tidak terblokir.
--   4. Hapus akun staff yg sudah ditangkap dari auth.users (cascade ke
--      profiles via ON DELETE CASCADE). Owner & admin TIDAK dihapus.
--
-- SECURITY DEFINER: butuh akses ke auth.users untuk hapus akun.
--
-- ⚠️ DESTRUKTIF & permanen.
-- ============================================================

CREATE OR REPLACE FUNCTION delete_outlet_cascade(p_outlet_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_staff_ids  UUID[];
  v_staff_deleted INT := 0;
BEGIN
  IF NOT is_owner() THEN
    RAISE EXCEPTION 'Hanya owner yang boleh menghapus cabang';
  END IF;

  -- 2. Tangkap id staff Kasir/Dapur cabang ini SEBELUM outlet dihapus
  SELECT array_agg(id) INTO v_staff_ids
  FROM profiles
  WHERE outlet_id = p_outlet_id
    AND role IN ('kasir', 'dapur');

  -- 3. Hapus outlet → cascade ke seluruh data transaksi (termasuk shifts)
  DELETE FROM outlets WHERE id = p_outlet_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  -- 4. Hapus akun staff (shift mereka sudah lenyap via cascade di atas)
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

GRANT EXECUTE ON FUNCTION delete_outlet_cascade(UUID) TO authenticated;

COMMENT ON FUNCTION delete_outlet_cascade IS
  'Hapus cabang + seluruh data transaksi (cascade) + akun staff Kasir/Dapur '
  'milik cabang tsb. Owner & admin tidak ikut terhapus. Hanya owner.';

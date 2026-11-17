-- RPC untuk hapus staff permanen (hapus dari auth.users → cascade ke profiles)
-- Hanya bisa dipanggil oleh owner atau admin

CREATE OR REPLACE FUNCTION delete_staff_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auth, public
AS $$
BEGIN
  -- Cek caller adalah owner atau admin
  IF NOT (is_owner() OR EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  )) THEN
    RAISE EXCEPTION 'Tidak punya akses';
  END IF;

  -- Cegah hapus diri sendiri
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Tidak bisa menghapus akun sendiri';
  END IF;

  -- Hapus dari auth.users → cascade ke profiles
  DELETE FROM auth.users WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User tidak ditemukan';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_staff_user(UUID) TO authenticated;

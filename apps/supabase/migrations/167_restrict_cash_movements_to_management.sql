-- 167_restrict_cash_movements_to_management.sql
--
-- Kas Masuk/Keluar adalah tindakan manajerial. Kasir tetap dapat membuka dan
-- menutup shift, tetapi tidak boleh menambah atau mengurangi kas manual.
-- Pembatasan wajib berada di database karena menyembunyikan tombol saja masih
-- dapat dilewati dengan request RPC langsung.

CREATE OR REPLACE FUNCTION public.guard_cash_movement_management_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  -- Operasi internal/service tanpa JWT tetap tersedia untuk administrasi.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_role NOT IN ('owner', 'admin', 'manajer') THEN
    RAISE EXCEPTION
      'Kas Masuk/Keluar hanya dapat dicatat oleh Owner, Admin, atau Manajer'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_cash_movement_management_role()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_cash_movement_management_role
  ON public.cash_movements;
CREATE TRIGGER trg_guard_cash_movement_management_role
  BEFORE INSERT ON public.cash_movements
  FOR EACH ROW EXECUTE FUNCTION public.guard_cash_movement_management_role();

COMMENT ON FUNCTION public.guard_cash_movement_management_role() IS
  'Menolak Kas Masuk/Keluar dari role kasir/pelanggan; hanya '
  'owner, admin, dan manajer yang diizinkan.';

COMMENT ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) IS
  'Kas Masuk/Keluar khusus owner/admin/manajer. Kas Keluar otomatis membuat '
  'expenses dengan outlet, tanggal, kategori, nominal, dan pembuat yang sama.';

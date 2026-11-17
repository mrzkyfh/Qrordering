-- 168_cash_movement_management_access.sql
--
-- Menuntaskan pembatasan Kas Masuk/Keluar:
--   1. Kasir tidak dapat membaca cash_movements melalui REST/RLS.
--   2. RPC utama menolak kasir secara langsung, bukan hanya mengandalkan trigger.
--   3. Implementasi lama disimpan sebagai helper internal tanpa hak EXECUTE
--      untuk authenticated agar kompatibilitas logika kas keluar -> expense
--      tetap terjaga tanpa membuka endpoint bypass.

DROP POLICY IF EXISTS "cash_movements_select" ON public.cash_movements;
CREATE POLICY "cash_movements_select" ON public.cash_movements
  FOR SELECT TO authenticated
  USING (
    COALESCE(public.is_owner(), false)
    OR (
      outlet_id = public.auth_outlet_id()
      AND COALESCE(public.auth_role()::TEXT, '') IN ('admin', 'manajer')
    )
  );

DROP POLICY IF EXISTS "cash_movements_insert" ON public.cash_movements;
CREATE POLICY "cash_movements_insert" ON public.cash_movements
  FOR INSERT TO authenticated
  WITH CHECK (
    created_by = auth.uid()
    AND (
      COALESCE(public.is_owner(), false)
      OR (
        outlet_id = public.auth_outlet_id()
        AND COALESCE(public.auth_role()::TEXT, '') IN ('admin', 'manajer')
      )
    )
  );

-- Simpan implementasi atomik migration 150 sebagai helper internal.
ALTER FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) RENAME TO record_cash_movement_management_impl;

REVOKE ALL ON FUNCTION public.record_cash_movement_management_impl(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_cash_movement(
  p_shift_id UUID,
  p_outlet_id UUID,
  p_type TEXT,
  p_amount NUMERIC,
  p_note TEXT,
  p_expense_category TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer') THEN
    RAISE EXCEPTION
      'Kas Masuk/Keluar hanya dapat dicatat oleh Owner, Admin, atau Manajer'
      USING ERRCODE = '42501';
  END IF;

  RETURN public.record_cash_movement_management_impl(
    p_shift_id,
    p_outlet_id,
    p_type,
    p_amount,
    p_note,
    p_expense_category
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) IS
  'Kas Masuk/Keluar khusus owner/admin/manajer. Target harus berupa shift '
  'kasir aktif pada outlet yang sama; Kas Keluar otomatis membuat expense.';

-- Laporan tutup shift tetap perlu expected_cash untuk rekonsiliasi kasir, tetapi
-- rincian Kas Masuk/Keluar dan expense hanya boleh diterima role manajemen.
ALTER FUNCTION public.get_shift_close_report(UUID)
  RENAME TO get_shift_close_report_management_impl;

REVOKE ALL ON FUNCTION public.get_shift_close_report_management_impl(UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_shift_close_report(p_shift_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  v_result := public.get_shift_close_report_management_impl(p_shift_id);

  IF NOT COALESCE(public.is_owner(), false)
     AND v_role NOT IN ('admin', 'manajer') THEN
    v_result := v_result || jsonb_build_object(
      'cash_in', 0,
      'cash_out', 0,
      'expenses', '[]'::JSONB
    );
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_shift_close_report(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shift_close_report(UUID)
  TO authenticated;

COMMENT ON FUNCTION public.get_shift_close_report(UUID) IS
  'Laporan tutup shift. Rincian Kas Masuk/Keluar dan expense hanya dikembalikan '
  'kepada owner/admin/manajer; kasir menerima ringkasan rekonsiliasi.';

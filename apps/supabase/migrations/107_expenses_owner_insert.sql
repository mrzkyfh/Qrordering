-- 107_expenses_owner_insert.sql
-- BUG: owner tidak bisa MENCATAT pengeluaran.
--
-- Policy lama (005_rls.sql):
--     expenses_insert  WITH CHECK (outlet_id = auth_outlet_id())
--
-- Owner bersifat lintas-cabang: `profiles.outlet_id` miliknya null (atau menunjuk
-- satu outlet saja), sehingga `auth_outlet_id()` tidak pernah sama dengan outlet
-- yang dipilih di owner-panel → INSERT selalu ditolak RLS. Akibatnya pengeluaran
-- yang diinput owner tidak pernah tersimpan (dan otomatis tak muncul di dashboard).
--
-- Konsisten dengan expenses_update/expenses_delete yang sudah mengizinkan owner.
-- Manajer tetap tidak boleh insert (hanya admin/kasir di outletnya) — sama
-- seperti perilaku lama untuk non-owner.

DROP POLICY IF EXISTS "expenses_insert" ON expenses;
CREATE POLICY "expenses_insert" ON expenses
  FOR INSERT TO authenticated
  WITH CHECK (
    is_owner() OR outlet_id = auth_outlet_id()
  );

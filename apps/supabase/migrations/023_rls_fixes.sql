-- ============================================================
-- 023_rls_fixes.sql
-- Fix dari API testing remaining tables 2026-05-27
-- BUG-TBL-001, BUG-PAY-001, BUG-PAY-002, BUG-LOY-001
-- ============================================================

-- ── BUG-TBL-001 ──────────────────────────────────────────────
-- tables_update mengizinkan kasir ubah konfigurasi meja
-- (table_number, capacity, area, qr_token) karena tidak ada role check.
-- Fix: restrict ke owner/admin saja.
DROP POLICY IF EXISTS "tables_update" ON restaurant_tables;
CREATE POLICY "tables_update" ON restaurant_tables FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── BUG-PAY-001 ──────────────────────────────────────────────
-- payments_update tidak ada WITH CHECK → admin bisa pindah
-- outlet_id payment ke outlet lain.
DROP POLICY IF EXISTS "payments_update" ON payments;
CREATE POLICY "payments_update" ON payments FOR UPDATE
USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
)
WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── BUG-PAY-002 ──────────────────────────────────────────────
-- Tidak ada DELETE policy untuk payments.
-- Owner perlu bisa hapus payment yang salah input.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'payments' AND policyname = 'payments_delete'
  ) THEN
    EXECUTE 'CREATE POLICY "payments_delete" ON payments FOR DELETE USING (is_owner())';
  END IF;
END $$;

-- ── BUG-LOY-001 ──────────────────────────────────────────────
-- loyalty_txn_crud menggunakan FOR ALL → admin/kasir bisa UPDATE
-- dan DELETE riwayat poin member (fraud risk, audit trail rusak).
-- Fix: ganti ke SELECT + INSERT only, hapus UPDATE/DELETE.
DROP POLICY IF EXISTS "loyalty_txn_crud" ON loyalty_transactions;
DROP POLICY IF EXISTS "loyalty_txn_select" ON loyalty_transactions;
DROP POLICY IF EXISTS "loyalty_txn_insert" ON loyalty_transactions;

CREATE POLICY "loyalty_txn_select" ON loyalty_transactions FOR SELECT USING (
  outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
  OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
);

CREATE POLICY "loyalty_txn_insert" ON loyalty_transactions FOR INSERT WITH CHECK (
  outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
  OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
);
-- Tidak ada UPDATE/DELETE policy → loyalty_transactions immutable by default

-- menu_recipes.qty_per_portion sudah ada CHECK (qty_per_portion > 0) dari migration 009
-- BUG-REC-001 tidak valid — constraint sudah ada sejak awal.

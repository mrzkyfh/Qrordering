-- 088_cash_movements.sql
-- FITUR: Kas Masuk/Keluar selama shift (petty cash / paid-out).
-- Sebelumnya shift hanya punya rekonsiliasi buka/tutup → selisih kas di tengah
-- shift (bayar galon/ojek, setor sebagian, tambah modal) tak tercatat.
-- Tabel ini mencatat tiap pergerakan kas agar expected_cash saat tutup akurat.

CREATE TABLE IF NOT EXISTS cash_movements (
  id         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id   UUID          NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
  outlet_id  UUID          NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  type       TEXT          NOT NULL CHECK (type IN ('in', 'out')),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  note       TEXT,
  created_by UUID          REFERENCES profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cash_movements_shift ON cash_movements(shift_id);

-- ── RLS: tenant-scoped (pola migrasi 048) ───────────────────────────────────
ALTER TABLE cash_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cash_movements_select" ON cash_movements;
CREATE POLICY "cash_movements_select" ON cash_movements
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

-- Insert: hanya untuk outlet sendiri, dan actor = dirinya (anti-spoof created_by).
DROP POLICY IF EXISTS "cash_movements_insert" ON cash_movements;
CREATE POLICY "cash_movements_insert" ON cash_movements
  FOR INSERT TO authenticated
  WITH CHECK (
    outlet_id = auth_outlet_id()
    AND created_by = auth.uid()
  );

GRANT SELECT, INSERT ON cash_movements TO authenticated;

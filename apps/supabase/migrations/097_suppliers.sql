-- 097_suppliers.sql
-- FITUR NEW-4 (Fase 1b) — Supplier / pemasok bahan baku.
-- Mencatat "beli dari siapa" pada transaksi stok 'purchase'. Master data
-- sederhana + kolom supplier_id di stock_transactions + adjust_stock menerima
-- supplier_id.

-- ── Tabel suppliers ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS suppliers (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  phone      TEXT,
  note       TEXT,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_suppliers_outlet ON suppliers(outlet_id);

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "suppliers_select" ON suppliers;
CREATE POLICY "suppliers_select" ON suppliers
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

-- Tulis: owner, atau manajer+ (rank >= 2) pada outlet sendiri.
DROP POLICY IF EXISTS "suppliers_write" ON suppliers;
CREATE POLICY "suppliers_write" ON suppliers
  FOR ALL TO authenticated
  USING (is_owner() OR (auth_rank() >= 2 AND outlet_id = auth_outlet_id()))
  WITH CHECK (is_owner() OR (auth_rank() >= 2 AND outlet_id = auth_outlet_id()));

GRANT SELECT, INSERT, UPDATE, DELETE ON suppliers TO authenticated;

-- ── Kolom supplier_id di stock_transactions ─────────────────────────────────
ALTER TABLE stock_transactions
  ADD COLUMN IF NOT EXISTS supplier_id UUID REFERENCES suppliers(id) ON DELETE SET NULL;

-- ── adjust_stock: terima p_supplier_id ──────────────────────────────────────
DROP FUNCTION IF EXISTS adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID);
CREATE FUNCTION adjust_stock(
  p_outlet_id     UUID,
  p_ingredient_id UUID,
  p_type          text,
  p_qty           numeric,
  p_cost_per_unit numeric DEFAULT NULL,
  p_notes         text DEFAULT NULL,
  p_created_by    UUID DEFAULT NULL,
  p_supplier_id   UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql
SET search_path = public, extensions AS $$  -- SECURITY INVOKER (default): RLS tetap menegakkan outlet
DECLARE
  v_qty_before numeric;
  v_qty_after numeric;
  v_ingredient_outlet UUID;
BEGIN
  SELECT stock_qty, outlet_id
  INTO v_qty_before, v_ingredient_outlet
  FROM ingredients
  WHERE id = p_ingredient_id
  FOR UPDATE;

  IF v_ingredient_outlet IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'ingredient does not belong to the specified outlet';
  END IF;

  IF p_type IN ('purchase', 'return', 'adjustment') THEN
    v_qty_after := v_qty_before + p_qty;
  ELSE
    v_qty_after := v_qty_before - p_qty;  -- boleh negatif (sinyal oversell)
  END IF;

  INSERT INTO stock_transactions (
    outlet_id, ingredient_id, type,
    qty_before, qty, qty_after,
    cost_per_unit, notes, created_by, supplier_id
  ) VALUES (
    p_outlet_id, p_ingredient_id, p_type::stock_transaction_type,
    v_qty_before, p_qty, v_qty_after,
    p_cost_per_unit, p_notes, p_created_by, p_supplier_id
  );
END;
$$;

REVOKE ALL ON FUNCTION adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID, UUID) TO authenticated;

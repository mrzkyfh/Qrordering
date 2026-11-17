-- 101_waste.sql
-- FITUR ROADMAP-2 — Waste / Spoilage (bahan terbuang).
--
-- Tipe 'waste' sudah ada di stock_transaction_type + form StockManager. Yang
-- ditambah: kolom alasan (reason), adjust_stock menerima p_reason, dan view
-- v_waste untuk laporan kerugian per periode/alasan.

-- ── Kolom alasan pada stock_transactions ────────────────────────────────────
ALTER TABLE stock_transactions
  ADD COLUMN IF NOT EXISTS reason TEXT;   -- mis. expired|rusak|tumpah|lain (freeform)

-- ── adjust_stock: terima p_reason (disimpan; relevan untuk waste) ────────────
DROP FUNCTION IF EXISTS adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID, UUID);
CREATE FUNCTION adjust_stock(
  p_outlet_id     UUID,
  p_ingredient_id UUID,
  p_type          text,
  p_qty           numeric,
  p_cost_per_unit numeric DEFAULT NULL,
  p_notes         text DEFAULT NULL,
  p_created_by    UUID DEFAULT NULL,
  p_supplier_id   UUID DEFAULT NULL,
  p_reason        text DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql
SET search_path = public, extensions AS $$  -- SECURITY INVOKER (default): RLS menegakkan outlet
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
    v_qty_after := v_qty_before - p_qty;  -- usage/waste; boleh negatif (sinyal oversell)
  END IF;

  INSERT INTO stock_transactions (
    outlet_id, ingredient_id, type,
    qty_before, qty, qty_after,
    cost_per_unit, notes, created_by, supplier_id, reason
  ) VALUES (
    p_outlet_id, p_ingredient_id, p_type::stock_transaction_type,
    v_qty_before, p_qty, v_qty_after,
    p_cost_per_unit, p_notes, p_created_by, p_supplier_id, p_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID, UUID, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION adjust_stock(UUID, UUID, text, numeric, numeric, text, UUID, UUID, text) TO authenticated;

-- ── View laporan waste ──────────────────────────────────────────────────────
-- Nilai kerugian = qty × biaya (pakai cost_per_unit transaksi bila ada, else
-- cost_per_unit bahan saat ini). Tanggal di zona Asia/Jakarta.
DROP VIEW IF EXISTS v_waste;
CREATE VIEW v_waste AS
SELECT
  st.id,
  st.outlet_id,
  st.ingredient_id,
  i.name                                                   AS ingredient_name,
  i.unit                                                   AS unit,
  st.qty,
  COALESCE(st.cost_per_unit, i.cost_per_unit)              AS cost_per_unit,
  (st.qty * COALESCE(st.cost_per_unit, i.cost_per_unit))::numeric AS loss_value,
  st.reason,
  st.notes,
  st.created_by,
  st.created_at,
  (st.created_at AT TIME ZONE 'Asia/Jakarta')::date::text  AS waste_date
FROM stock_transactions st
JOIN ingredients i ON i.id = st.ingredient_id
WHERE st.type = 'waste';

GRANT SELECT ON v_waste TO authenticated;
ALTER VIEW v_waste SET (security_invoker = on);

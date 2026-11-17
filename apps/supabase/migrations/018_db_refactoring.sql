-- ============================================================
-- 018_db_refactoring.sql
-- Database refactoring for stock transactions and shift closing
-- ============================================================

-- 1. Add non-negative loyalty points constraint (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_points_non_negative'
      AND conrelid = 'loyalty_members'::regclass
  ) THEN
    ALTER TABLE loyalty_members ADD CONSTRAINT chk_points_non_negative CHECK (points >= 0);
  END IF;
END $$;

-- 2. Create adjust_stock RPC function to prevent TOCTOU race conditions
CREATE OR REPLACE FUNCTION adjust_stock(
  p_outlet_id UUID,
  p_ingredient_id UUID,
  p_type text,
  p_qty numeric,
  p_cost_per_unit numeric DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_created_by UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_qty_before numeric;
  v_qty_after numeric;
BEGIN
  -- Get current stock quantity with row lock to prevent race conditions
  SELECT stock_qty INTO v_qty_before
  FROM ingredients
  WHERE id = p_ingredient_id
  FOR UPDATE;

  IF p_type IN ('purchase', 'return', 'adjustment') THEN
    v_qty_after := v_qty_before + p_qty;
  ELSE
    v_qty_after := GREATEST(v_qty_before - p_qty, 0);
  END IF;

  INSERT INTO stock_transactions (
    outlet_id,
    ingredient_id,
    type,
    qty_before,
    qty,
    qty_after,
    cost_per_unit,
    notes,
    created_by
  ) VALUES (
    p_outlet_id,
    p_ingredient_id,
    p_type::stock_transaction_type,
    v_qty_before,
    p_qty,
    v_qty_after,
    p_cost_per_unit,
    p_notes,
    p_created_by
  );
END;
$$;

-- 3. Create close_shift RPC function to calculate shift balances atomically
CREATE OR REPLACE FUNCTION close_shift(
  p_shift_id UUID,
  p_closing_cash numeric,
  p_notes text DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_cash_total numeric := 0;
  v_opening_cash numeric := 0;
  v_expected_cash numeric := 0;
  v_cash_difference numeric := 0;
BEGIN
  -- Sum all cash payments for paid orders in this shift
  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM payments p
  JOIN orders o ON o.id = p.order_id
  WHERE o.shift_id = p_shift_id
    AND o.status = 'paid'
    AND p.method = 'cash';

  -- Get opening cash with row lock for the shift
  SELECT opening_cash INTO v_opening_cash
  FROM shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  v_expected_cash := v_opening_cash + v_cash_total;
  v_cash_difference := p_closing_cash - v_expected_cash;

  -- Update shift
  UPDATE shifts
  SET end_time = NOW(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

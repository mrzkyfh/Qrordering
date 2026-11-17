-- Fix stock_tx_insert RLS: owner profile has no outlet_id so
-- auth_outlet_id() returns null, causing all owner stock adjustments
-- to fail (including via the adjust_stock RPC which is SECURITY INVOKER).
DROP POLICY IF EXISTS "stock_tx_insert" ON stock_transactions;
CREATE POLICY "stock_tx_insert" ON stock_transactions FOR INSERT WITH CHECK (
  is_owner() OR outlet_id = auth_outlet_id()
);

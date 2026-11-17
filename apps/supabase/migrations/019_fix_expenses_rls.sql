-- Fix expenses_insert RLS: owner has no outlet_id in profile so
-- auth_outlet_id() returns null, causing all owner inserts to fail.
DROP POLICY IF EXISTS "expenses_insert" ON expenses;
CREATE POLICY "expenses_insert" ON expenses FOR INSERT WITH CHECK (
  is_owner() OR outlet_id = auth_outlet_id()
);

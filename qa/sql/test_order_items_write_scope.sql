-- Regression: order_items writes must go through trusted RPCs.
-- Run with: supabase db query --linked --file qa/sql/test_order_items_write_scope.sql

DO $$
DECLARE
  v_update boolean;
  v_delete boolean;
  v_policy_count integer;
BEGIN
  SELECT has_table_privilege('anon', 'public.order_items', 'UPDATE')
      OR has_table_privilege('authenticated', 'public.order_items', 'UPDATE')
    INTO v_update;
  SELECT has_table_privilege('anon', 'public.order_items', 'DELETE')
      OR has_table_privilege('authenticated', 'public.order_items', 'DELETE')
    INTO v_delete;
  IF v_update OR v_delete THEN
    RAISE EXCEPTION 'anon still has direct order_items write privilege';
  END IF;

  SELECT count(*)
    INTO v_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'order_items'
    AND policyname IN ('order_items_update', 'order_items_delete');
  IF v_policy_count <> 0 THEN
    RAISE EXCEPTION 'direct order_items write policies still exist';
  END IF;

  RAISE NOTICE 'PASS: direct order_items UPDATE/DELETE are blocked';
END;
$$;

SELECT CASE
  WHEN NOT has_table_privilege('anon', 'public.order_items', 'UPDATE')
   AND NOT has_table_privilege('authenticated', 'public.order_items', 'UPDATE')
   AND NOT has_table_privilege('anon', 'public.order_items', 'DELETE')
   AND NOT has_table_privilege('authenticated', 'public.order_items', 'DELETE')
   AND NOT EXISTS (
     SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'order_items'
       AND policyname IN ('order_items_update', 'order_items_delete')
   )
  THEN '✅ ORDER ITEM DIRECT WRITE TEST PASSED'
  ELSE '❌ ORDER ITEM DIRECT WRITE TEST FAILED'
END AS summary;

-- Regression contract for internal RPC execution scope.
-- Run with: supabase db query --linked --file qa/sql/audit_internal_rpc_scope.sql
BEGIN;

CREATE TEMP TABLE _internal_rpc_scope_results (
  test_case TEXT,
  signature TEXT,
  actual TEXT,
  status TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_sig regprocedure;
  v_anon BOOLEAN;
  v_auth BOOLEAN;
  v_service BOOLEAN;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.deduct_stock_for_items(uuid,uuid[])'::regprocedure,
    'public._find_approver(uuid,text,uuid)'::regprocedure,
    'public.assign_order_payment_context(uuid,uuid,boolean)'::regprocedure,
    'public.record_pos_payment_internal(uuid,uuid,uuid,public.payment_method,numeric,text,text,boolean,timestamp with time zone)'::regprocedure
  ] LOOP
    v_anon := has_function_privilege('anon', v_sig, 'EXECUTE');
    v_auth := has_function_privilege('authenticated', v_sig, 'EXECUTE');
    v_service := has_function_privilege('service_role', v_sig, 'EXECUTE');

    INSERT INTO _internal_rpc_scope_results
      (test_case, signature, actual, status)
    VALUES
      ('deny client roles', v_sig::TEXT,
       format('anon=%s authenticated=%s service_role=%s', v_anon, v_auth, v_service),
       CASE WHEN NOT v_anon AND NOT v_auth AND v_service
            THEN '✅ PASS' ELSE '❌ FAIL' END);
  END LOOP;
END $$;

SELECT * FROM _internal_rpc_scope_results ORDER BY signature;
SELECT CASE
  WHEN count(*) FILTER (WHERE status = '❌ FAIL') = 0
  THEN '✅ ALL INTERNAL RPC SCOPE TESTS PASSED'
  ELSE '❌ INTERNAL RPC SCOPE TEST FAILED'
END AS summary
FROM _internal_rpc_scope_results;

ROLLBACK;

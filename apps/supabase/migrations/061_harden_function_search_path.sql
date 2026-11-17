-- ============================================================
-- 061_harden_function_search_path.sql
-- Fix linter 0011 (function_search_path_mutable).
--
-- Set search_path tetap pada semua function yang ter-flag. Pakai
-- `public, extensions` (superset aman) supaya function yang memakai
-- pgcrypto/ekstensi lain tetap resolve. Murni hardening — tanpa ubah logika.
-- ============================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'update_updated_at','generate_order_number','sync_table_status',
        'apply_stock_transaction','increment_promo_usage','auth_role',
        'auth_outlet_id','is_owner','is_self_order','deduct_stock_for_order',
        'restore_stock_for_order','handle_order_stock_trigger',
        'update_loyalty_member_timestamp','adjust_stock','close_shift',
        'validate_order_status_transition','validate_order_item_insert',
        'set_order_void_audit','delete_menu_item_smart','delete_ingredient_smart',
        'restore_menu_item','restore_ingredient','set_order_cancel_audit'
      )
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions', r.sig);
  END LOOP;
END $$;

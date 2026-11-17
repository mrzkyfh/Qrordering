-- ============================================================
-- 062_revoke_sensitive_rpc_grants.sql
-- Fix linter 0028/0029 (SECURITY DEFINER function executable via REST)
-- untuk function yang JELAS tidak boleh dipanggil sebagai RPC publik.
--
-- CATATAN: function alur customer (anon) seperti validate_promo_code,
-- find_loyalty_member_by_phone, get_next_order_number, dll TIDAK disentuh
-- karena memang sengaja dipanggil anon dari customer-menu. Lihat ringkasan.
-- ============================================================

-- ── Function TRIGGER: cabut EXECUTE dari semua role ───────────────────────────
-- Trigger tetap berjalan tanpa hak EXECUTE; hanya menutup endpoint /rpc-nya.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'update_updated_at','sync_table_status','handle_order_stock_trigger',
        'update_loyalty_member_timestamp','validate_order_status_transition',
        'validate_order_item_insert','set_order_void_audit','set_order_cancel_audit',
        'handle_new_user','handle_user_login','enforce_refund_permission'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;

-- ── RPC admin-only: cabut anon & public, pastikan authenticated tetap bisa ────
-- (function ini memeriksa role owner/admin di dalamnya).
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'admin_set_user_pin','delete_staff_user','delete_outlet_cascade',
        'delete_menu_item_smart','delete_ingredient_smart',
        'restore_menu_item','restore_ingredient','adjust_stock','close_shift'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;
END $$;

-- ── set_my_pin: tidak boleh dipanggil siapa pun (PIN hanya via admin_set_user_pin)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'set_my_pin'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;

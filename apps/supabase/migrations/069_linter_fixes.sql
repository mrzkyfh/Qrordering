-- ============================================================
-- 069_linter_fixes.sql
-- Perbaikan dari Supabase Security Linter:
--   1. role_rank: tambah SET search_path (function_search_path_mutable)
--   2. REVOKE anon dari semua fungsi yang tidak perlu diakses publik
--      (anon_security_definer_function_executable)
--   3. Pastikan _find_approver & verify_staff_pin tidak bisa diakses siapapun
--      kecuali SECURITY DEFINER context (internal helper)
-- ============================================================

-- ── 1. role_rank: perbaiki mutable search_path ───────────────────────────────
CREATE OR REPLACE FUNCTION role_rank(p_role user_role)
RETURNS INT LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_role
    WHEN 'owner'   THEN 4
    WHEN 'admin'   THEN 3
    WHEN 'manajer' THEN 2
    WHEN 'kasir'   THEN 1
    WHEN 'dapur'   THEN 1
    ELSE 0
  END
$$;

-- ── 2. Cabut akses anon dari semua fungsi sensitif ───────────────────────────
-- Fungsi-fungsi di bawah tidak pernah perlu dipanggil tanpa login.

-- _find_approver: helper internal (dipanggil dari SECURITY DEFINER RPC saja)
REVOKE EXECUTE ON FUNCTION _find_approver(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- verify_staff_pin: hanya dipanggil oleh edge function clock-in via service_role
REVOKE EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) TO service_role;

-- Approval RPCs: hanya authenticated (kasir yang sudah login)
REVOKE EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT) TO authenticated;

REVOKE EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT) TO authenticated;

-- set_staff_pin & admin_set_user_pin: hanya authenticated
REVOKE EXECUTE ON FUNCTION set_staff_pin(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION set_staff_pin(UUID, TEXT) TO authenticated;

REVOKE EXECUTE ON FUNCTION admin_set_user_pin(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_set_user_pin(UUID, TEXT) TO authenticated;

-- Stok & order helpers: hanya authenticated
REVOKE EXECUTE ON FUNCTION deduct_stock_for_order(UUID)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION deduct_stock_for_order(UUID)  TO authenticated;

REVOKE EXECUTE ON FUNCTION restore_stock_for_order(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION restore_stock_for_order(UUID) TO authenticated;

REVOKE EXECUTE ON FUNCTION award_loyalty_points(UUID, UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION award_loyalty_points(UUID, UUID) TO authenticated;

REVOKE EXECUTE ON FUNCTION redeem_loyalty_points(UUID, UUID, INT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_loyalty_points(UUID, UUID, INT) TO authenticated;

REVOKE EXECUTE ON FUNCTION validate_loyalty_redeem(UUID, INT, NUMERIC, NUMERIC) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION validate_loyalty_redeem(UUID, INT, NUMERIC, NUMERIC) TO authenticated;

-- delete/restore staff & outlet: hanya authenticated (sudah ada cek role di dalam fungsi)
REVOKE EXECUTE ON FUNCTION delete_staff_user(UUID)      FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION delete_staff_user(UUID)      TO authenticated;

REVOKE EXECUTE ON FUNCTION delete_outlet_cascade(UUID)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION delete_outlet_cascade(UUID)  TO authenticated;

REVOKE EXECUTE ON FUNCTION delete_ingredient_smart(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION delete_ingredient_smart(UUID) TO authenticated;

REVOKE EXECUTE ON FUNCTION delete_menu_item_smart(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION delete_menu_item_smart(UUID) TO authenticated;

REVOKE EXECUTE ON FUNCTION restore_ingredient(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION restore_ingredient(UUID) TO authenticated;

REVOKE EXECUTE ON FUNCTION restore_menu_item(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION restore_menu_item(UUID) TO authenticated;

-- list_clockin_staff: wajib authenticated (device session), sudah di migration 066
-- tapi kita perkuat ulang agar sinkron setelah CREATE OR REPLACE
REVOKE EXECUTE ON FUNCTION list_clockin_staff(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION list_clockin_staff(UUID) TO authenticated;

-- ── 3. Auth helper: bersihkan anon (nilai mereka NULL/false tanpa session) ────
-- Tetap biarkan authenticated karena dipakai di RLS
REVOKE EXECUTE ON FUNCTION auth_outlet_id() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION auth_outlet_id() TO authenticated;

REVOKE EXECUTE ON FUNCTION auth_rank() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION auth_rank() TO authenticated;

REVOKE EXECUTE ON FUNCTION auth_role() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION auth_role() TO authenticated;

REVOKE EXECUTE ON FUNCTION is_owner() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION is_owner() TO authenticated;

REVOKE EXECUTE ON FUNCTION has_my_pin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION has_my_pin() TO authenticated;

REVOKE EXECUTE ON FUNCTION verify_my_pin(TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION verify_my_pin(TEXT) TO authenticated;

-- ── Fungsi yang MEMANG perlu anon (self-order / customer menu) ─────────────────
-- apply_promo_usage, find_loyalty_member_by_phone, get_next_order_number,
-- validate_promo_code, is_self_order, is_self_order_item, validate_loyalty_redeem
-- → sudah GRANT ke anon di migrasi sebelumnya; tidak diubah di sini.
-- Bucket menu-images & qr-codes: public read adalah desain (URL gambar menu
-- dan QR meja harus bisa diakses tanpa login oleh pelanggan).

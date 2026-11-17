-- ============================================================
-- 037_smart_delete_rpcs.sql
-- Smart delete: hard delete kalau bisa, soft delete (is_active=false)
-- kalau data sudah punya referensi historis (order_items, stock_tx).
--
-- Tujuan: bersihkan storage Supabase tanpa kehilangan laporan historis.
--
-- Return JSONB: { status: 'deleted' | 'archived', reason: text? }
-- ============================================================

-- ── delete_menu_item_smart ──────────────────────────────────
-- Cek: order_items reference?
--   YES → soft delete (archive)
--   NO  → hard delete (cascade: menu_recipes ikut hilang)

CREATE OR REPLACE FUNCTION delete_menu_item_smart(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_has_orders BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM order_items WHERE menu_item_id = p_id)
    INTO v_has_orders;

  IF v_has_orders THEN
    UPDATE menu_items
      SET is_active = false, is_available = false
      WHERE id = p_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'not_found');
    END IF;
    RETURN jsonb_build_object(
      'status', 'archived',
      'reason', 'Menu sudah pernah dipesan — di-arsipkan agar laporan tetap akurat'
    );
  ELSE
    DELETE FROM menu_items WHERE id = p_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'not_found');
    END IF;
    RETURN jsonb_build_object('status', 'deleted');
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_menu_item_smart(UUID) TO authenticated;

COMMENT ON FUNCTION delete_menu_item_smart IS
  'Hard delete kalau menu belum pernah masuk order_items. '
  'Soft delete (is_active=false) kalau sudah ada history.';

-- ── delete_ingredient_smart ─────────────────────────────────
-- Cek: stock_transactions reference?
--   YES → soft delete
--   NO  → hard delete (cascade: menu_recipes ikut hilang)

CREATE OR REPLACE FUNCTION delete_ingredient_smart(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_has_tx BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM stock_transactions WHERE ingredient_id = p_id)
    INTO v_has_tx;

  IF v_has_tx THEN
    UPDATE ingredients
      SET is_active = false
      WHERE id = p_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'not_found');
    END IF;
    RETURN jsonb_build_object(
      'status', 'archived',
      'reason', 'Bahan baku sudah ada transaksi stok — di-arsipkan untuk audit'
    );
  ELSE
    DELETE FROM ingredients WHERE id = p_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'not_found');
    END IF;
    RETURN jsonb_build_object('status', 'deleted');
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_ingredient_smart(UUID) TO authenticated;

COMMENT ON FUNCTION delete_ingredient_smart IS
  'Hard delete kalau bahan belum pernah ada stock_transactions. '
  'Soft delete kalau sudah ada history.';

-- ── (Bonus) restore_menu_item / restore_ingredient ──────────
-- Untuk un-archive data yang di-soft-delete

CREATE OR REPLACE FUNCTION restore_menu_item(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE menu_items
    SET is_active = true, is_available = true
    WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  RETURN jsonb_build_object('status', 'restored');
END;
$$;

GRANT EXECUTE ON FUNCTION restore_menu_item(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION restore_ingredient(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE ingredients
    SET is_active = true
    WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  RETURN jsonb_build_object('status', 'restored');
END;
$$;

GRANT EXECUTE ON FUNCTION restore_ingredient(UUID) TO authenticated;

-- ============================================================
-- 049_smart_delete_clear_image.sql
-- Saat menu di-arsipkan (soft delete), kosongkan image_url.
--
-- File gambar fisik di bucket 'menu-images' dihapus oleh frontend
-- (best-effort) baik saat hard delete maupun arsip. Mengosongkan
-- image_url di sini mencegah "link nyangkut" ke file yang sudah
-- tidak ada. Gambar tidak dipakai di laporan/struk, jadi aman.
--
-- Revisi dari 037_smart_delete_rpcs.sql — hanya cabang arsip yang
-- berubah (tambah image_url = NULL).
-- ============================================================

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
      SET is_active = false, is_available = false, image_url = NULL
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
  'Soft delete (is_active=false, image_url=NULL) kalau sudah ada history.';

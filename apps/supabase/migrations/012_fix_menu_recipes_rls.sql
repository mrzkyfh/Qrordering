-- ============================================================
-- 012_fix_menu_recipes_rls.sql
--
-- BUG-005: menu_recipes menggunakan USING(TRUE) tanpa filter outlet.
-- Authenticated user dari outlet manapun bisa baca/tulis resep outlet lain.
--
-- FIX: Ganti policy dengan isolasi outlet via join ke menu_items,
-- pola sama dengan order_items → orders di migration 005.
-- ============================================================

-- Hapus policy lama yang terlalu longgar
DROP POLICY IF EXISTS "authenticated can manage recipes" ON menu_recipes;

-- SELECT: owner bisa lihat semua, selainnya hanya outlet sendiri
CREATE POLICY "recipes_select" ON menu_recipes FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM menu_items mi
    WHERE mi.id = menu_recipes.menu_item_id
      AND (is_owner() OR mi.outlet_id = auth_outlet_id())
  )
);

-- INSERT: hanya admin/owner yang boleh tambah resep, ke outlet sendiri
CREATE POLICY "recipes_insert" ON menu_recipes FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM menu_items mi
    WHERE mi.id = menu_recipes.menu_item_id
      AND (is_owner() OR (auth_role() = 'admin' AND mi.outlet_id = auth_outlet_id()))
  )
);

-- UPDATE: owner atau admin outlet sendiri
CREATE POLICY "recipes_update" ON menu_recipes FOR UPDATE USING (
  EXISTS (
    SELECT 1 FROM menu_items mi
    WHERE mi.id = menu_recipes.menu_item_id
      AND (is_owner() OR (auth_role() = 'admin' AND mi.outlet_id = auth_outlet_id()))
  )
);

-- DELETE: owner atau admin outlet sendiri
CREATE POLICY "recipes_delete" ON menu_recipes FOR DELETE USING (
  EXISTS (
    SELECT 1 FROM menu_items mi
    WHERE mi.id = menu_recipes.menu_item_id
      AND (is_owner() OR (auth_role() = 'admin' AND mi.outlet_id = auth_outlet_id()))
  )
);

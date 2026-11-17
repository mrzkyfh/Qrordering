-- ============================================================
-- 048_rls_tenant_scope.sql
-- Fix audit CRITICAL: policy RLS over-permissive `USING (TRUE)` yang
-- memungkinkan akses/tulis LINTAS-OUTLET. Semua di-scope ke outlet user
-- (is_owner() OR outlet_id = auth_outlet_id()), tabel anak via join induk.
--
-- Aman dijalankan ulang (DROP POLICY IF EXISTS sebelum CREATE).
-- Menggantikan policy dari: 009 (menu_recipes), 038 (order_item_options),
-- 039 (menu_extras, menu_extra_options, menu_item_extras).
-- ============================================================

-- ── menu_extras (punya outlet_id langsung) ────────────────────────────────────
DROP POLICY IF EXISTS "extras_select_auth" ON menu_extras;
DROP POLICY IF EXISTS "extras_insert"      ON menu_extras;
DROP POLICY IF EXISTS "extras_update"      ON menu_extras;
DROP POLICY IF EXISTS "extras_delete"      ON menu_extras;

CREATE POLICY "extras_select_auth" ON menu_extras
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());
CREATE POLICY "extras_insert" ON menu_extras
  FOR INSERT TO authenticated
  WITH CHECK (is_owner() OR outlet_id = auth_outlet_id());
CREATE POLICY "extras_update" ON menu_extras
  FOR UPDATE TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id())
  WITH CHECK (is_owner() OR outlet_id = auth_outlet_id());
CREATE POLICY "extras_delete" ON menu_extras
  FOR DELETE TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());
-- extras_select_anon (is_active = TRUE) dari 039 dibiarkan — sudah aman.

-- ── menu_extra_options (scope via induk menu_extras) ──────────────────────────
DROP POLICY IF EXISTS "meo_select_auth" ON menu_extra_options;
DROP POLICY IF EXISTS "meo_select_anon" ON menu_extra_options;
DROP POLICY IF EXISTS "meo_insert"      ON menu_extra_options;
DROP POLICY IF EXISTS "meo_update"      ON menu_extra_options;
DROP POLICY IF EXISTS "meo_delete"      ON menu_extra_options;

CREATE POLICY "meo_select_auth" ON menu_extra_options
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_extras e
                 WHERE e.id = menu_extra_options.extra_id
                   AND (is_owner() OR e.outlet_id = auth_outlet_id())));
CREATE POLICY "meo_select_anon" ON menu_extra_options
  FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM menu_extras e
                 WHERE e.id = menu_extra_options.extra_id AND e.is_active));
CREATE POLICY "meo_insert" ON menu_extra_options
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM menu_extras e
                      WHERE e.id = menu_extra_options.extra_id
                        AND (is_owner() OR e.outlet_id = auth_outlet_id())));
CREATE POLICY "meo_update" ON menu_extra_options
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_extras e
                 WHERE e.id = menu_extra_options.extra_id
                   AND (is_owner() OR e.outlet_id = auth_outlet_id())));
CREATE POLICY "meo_delete" ON menu_extra_options
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_extras e
                 WHERE e.id = menu_extra_options.extra_id
                   AND (is_owner() OR e.outlet_id = auth_outlet_id())));

-- ── menu_item_extras (scope via induk menu_items) ─────────────────────────────
DROP POLICY IF EXISTS "mie_select_auth" ON menu_item_extras;
DROP POLICY IF EXISTS "mie_select_anon" ON menu_item_extras;
DROP POLICY IF EXISTS "mie_insert"      ON menu_item_extras;
DROP POLICY IF EXISTS "mie_delete"      ON menu_item_extras;

CREATE POLICY "mie_select_auth" ON menu_item_extras
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_item_extras.menu_item_id
                   AND (is_owner() OR mi.outlet_id = auth_outlet_id())));
CREATE POLICY "mie_select_anon" ON menu_item_extras
  FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_item_extras.menu_item_id
                   AND mi.is_active AND mi.is_available));
CREATE POLICY "mie_insert" ON menu_item_extras
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM menu_items mi
                      WHERE mi.id = menu_item_extras.menu_item_id
                        AND (is_owner() OR mi.outlet_id = auth_outlet_id())));
CREATE POLICY "mie_delete" ON menu_item_extras
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_item_extras.menu_item_id
                   AND (is_owner() OR mi.outlet_id = auth_outlet_id())));

-- ── order_item_options (scope via order_items → orders.outlet_id) ─────────────
DROP POLICY IF EXISTS "oio_select"      ON order_item_options;
DROP POLICY IF EXISTS "oio_insert_anon" ON order_item_options;
DROP POLICY IF EXISTS "oio_insert_auth" ON order_item_options;

CREATE POLICY "oio_select" ON order_item_options
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    WHERE oi.id = order_item_options.order_item_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())));

-- Anon hanya boleh insert opsi untuk order_item milik self_order
CREATE POLICY "oio_insert_anon" ON order_item_options
  FOR INSERT TO anon
  WITH CHECK (EXISTS (
    SELECT 1 FROM order_items oi
    WHERE oi.id = order_item_options.order_item_id
      AND is_self_order(oi.order_id)));

CREATE POLICY "oio_insert_auth" ON order_item_options
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    WHERE oi.id = order_item_options.order_item_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())));

-- ── menu_recipes (scope via menu_items.outlet_id) ─────────────────────────────
DROP POLICY IF EXISTS "authenticated can manage recipes" ON menu_recipes;
-- Keempat policy recipes_* sudah dibuat migration 012; TANPA drop di bawah ini,
-- CREATE POLICY berikutnya gagal "already exists" dan mematikan rantai migration
-- dari DB kosong — melanggar janji di header berkas ini ("aman dijalankan
-- ulang"). Di DB yang sudah ada, drop-lalu-create ini hanya menyegarkan
-- definisinya ke versi tenant-scoped di bawah.
DROP POLICY IF EXISTS "recipes_select" ON menu_recipes;
DROP POLICY IF EXISTS "recipes_insert" ON menu_recipes;
DROP POLICY IF EXISTS "recipes_update" ON menu_recipes;
DROP POLICY IF EXISTS "recipes_delete" ON menu_recipes;

CREATE POLICY "recipes_select" ON menu_recipes
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_recipes.menu_item_id
                   AND (is_owner() OR mi.outlet_id = auth_outlet_id())));
CREATE POLICY "recipes_insert" ON menu_recipes
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM menu_items mi
                      WHERE mi.id = menu_recipes.menu_item_id
                        AND (is_owner() OR mi.outlet_id = auth_outlet_id())));
CREATE POLICY "recipes_update" ON menu_recipes
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_recipes.menu_item_id
                   AND (is_owner() OR mi.outlet_id = auth_outlet_id())))
  WITH CHECK (EXISTS (SELECT 1 FROM menu_items mi
                      WHERE mi.id = menu_recipes.menu_item_id
                        AND (is_owner() OR mi.outlet_id = auth_outlet_id())));
CREATE POLICY "recipes_delete" ON menu_recipes
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM menu_items mi
                 WHERE mi.id = menu_recipes.menu_item_id
                   AND (is_owner() OR mi.outlet_id = auth_outlet_id())));

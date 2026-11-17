-- ============================================================
-- 026_auth_anon_rpc_fixes.sql
-- Fix dari API testing final 2026-05-27
-- BUG-AUTH-001, BUG-ANON-001..003, BUG-RPC-003..005, BUG-TABLE-001
-- ============================================================

-- ── BUG-AUTH-001 ─────────────────────────────────────────────
-- handle_new_user membaca role dari raw_user_meta_data → siapapun
-- bisa signup dengan role='owner'. Fix: selalu assign 'kasir'.
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO profiles (id, full_name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    'kasir'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ── BUG-ANON-001: restaurant_tables anon scope ───────────────
-- Anon bisa enumerate semua meja semua outlet.
-- Fix: tetap izinkan SELECT tapi frontend WAJIB filter by qr_token.
-- RLS tidak bisa enforce filter query param, tapi batasi ke outlet aktif.
DROP POLICY IF EXISTS "tables_select_anon" ON restaurant_tables;
CREATE POLICY "tables_select_anon" ON restaurant_tables FOR SELECT TO anon
  USING (
    is_active = true
    AND qr_token IS NOT NULL
  );

-- ── BUG-ANON-002: menu_items anon scope ──────────────────────
DROP POLICY IF EXISTS "menu_items_select_anon" ON menu_items;
CREATE POLICY "menu_items_select_anon" ON menu_items FOR SELECT TO anon
  USING (
    is_available = true
    AND is_active = true
    AND outlet_id IN (SELECT id FROM outlets WHERE is_active = true)
  );

-- ── BUG-ANON-003: menu_categories anon scope ─────────────────
DROP POLICY IF EXISTS "menu_categories_select_anon" ON menu_categories;
CREATE POLICY "menu_categories_select_anon" ON menu_categories FOR SELECT TO anon
  USING (
    is_active = true
    AND outlet_id IN (SELECT id FROM outlets WHERE is_active = true)
  );

-- ── BUG-RPC-003: increment_promo_usage callable by anon ──────
REVOKE ALL ON FUNCTION increment_promo_usage(UUID) FROM public;
GRANT EXECUTE ON FUNCTION increment_promo_usage(UUID) TO authenticated;

-- ── BUG-RPC-004: generate_order_number callable by anon ──────
REVOKE ALL ON FUNCTION generate_order_number(UUID) FROM public;
GRANT EXECUTE ON FUNCTION generate_order_number(UUID) TO authenticated;

-- ── BUG-RPC-005: is_self_order tanpa SET search_path ─────────
CREATE OR REPLACE FUNCTION is_self_order(p_order_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM orders
    WHERE id = p_order_id AND order_type = 'self_order'
  );
$$;

-- ── BUG-TABLE-001: menu_departments tidak ada ────────────────
CREATE TABLE IF NOT EXISTS menu_departments (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  color      TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_menu_departments_outlet
  ON menu_departments(outlet_id);

ALTER TABLE menu_departments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "menu_departments_select" ON menu_departments;
CREATE POLICY "menu_departments_select" ON menu_departments FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);

DROP POLICY IF EXISTS "menu_departments_insert" ON menu_departments;
CREATE POLICY "menu_departments_insert" ON menu_departments FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

DROP POLICY IF EXISTS "menu_departments_update" ON menu_departments;
CREATE POLICY "menu_departments_update" ON menu_departments FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

DROP POLICY IF EXISTS "menu_departments_delete" ON menu_departments;
CREATE POLICY "menu_departments_delete" ON menu_departments FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- Tambah department_id ke menu_categories (FK ke menu_departments)
ALTER TABLE menu_categories
  ADD COLUMN IF NOT EXISTS department_id UUID
    REFERENCES menu_departments(id) ON DELETE SET NULL;

-- ============================================================
-- 005_rls.sql
-- Row Level Security — isolasi data antar outlet & role
-- ============================================================

-- ── Helper functions ─────────────────────────────────────────

-- Ambil role user yang sedang login
CREATE OR REPLACE FUNCTION auth_role()
RETURNS user_role LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role FROM profiles WHERE id = auth.uid()
$$;

-- Ambil outlet_id user yang sedang login
CREATE OR REPLACE FUNCTION auth_outlet_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT outlet_id FROM profiles WHERE id = auth.uid()
$$;

-- Cek apakah user adalah owner
CREATE OR REPLACE FUNCTION is_owner()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role = 'owner' FROM profiles WHERE id = auth.uid()
$$;

-- ── Enable RLS pada semua tabel ──────────────────────────────
ALTER TABLE outlets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_tables   ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_categories     ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts               ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders               ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments             ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingredients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transactions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE promos               ENABLE ROW LEVEL SECURITY;
ALTER TABLE vouchers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses             ENABLE ROW LEVEL SECURITY;

-- ── OUTLETS ──────────────────────────────────────────────────
-- Owner: semua outlet
-- Admin/kasir/dapur: hanya outlet sendiri
CREATE POLICY "outlets_select" ON outlets FOR SELECT USING (
  is_owner() OR id = auth_outlet_id()
);
CREATE POLICY "outlets_insert" ON outlets FOR INSERT WITH CHECK (is_owner());
CREATE POLICY "outlets_update" ON outlets FOR UPDATE USING (
  is_owner() OR id = auth_outlet_id()
);
CREATE POLICY "outlets_delete" ON outlets FOR DELETE USING (is_owner());

-- ── PROFILES ─────────────────────────────────────────────────
-- Owner: semua profil
-- Admin: profil di outlet sendiri + profil sendiri
-- Kasir/dapur: hanya profil sendiri
CREATE POLICY "profiles_select" ON profiles FOR SELECT USING (
  is_owner()
  OR outlet_id = auth_outlet_id()
  OR id = auth.uid()
);
CREATE POLICY "profiles_insert" ON profiles FOR INSERT WITH CHECK (
  id = auth.uid()  -- dibuat otomatis via trigger handle_new_user
  OR is_owner()
  OR auth_role() = 'admin'
);
CREATE POLICY "profiles_update" ON profiles FOR UPDATE USING (
  id = auth.uid()
  OR is_owner()
  OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "profiles_delete" ON profiles FOR DELETE USING (is_owner());

-- ── RESTAURANT_TABLES ────────────────────────────────────────
CREATE POLICY "tables_select" ON restaurant_tables FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "tables_insert" ON restaurant_tables FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "tables_update" ON restaurant_tables FOR UPDATE USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "tables_delete" ON restaurant_tables FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── MENU_CATEGORIES ──────────────────────────────────────────
CREATE POLICY "menu_categories_select" ON menu_categories FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "menu_categories_insert" ON menu_categories FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() IN ('admin') AND outlet_id = auth_outlet_id())
);
CREATE POLICY "menu_categories_update" ON menu_categories FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "menu_categories_delete" ON menu_categories FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── MENU_ITEMS ───────────────────────────────────────────────
CREATE POLICY "menu_items_select" ON menu_items FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "menu_items_insert" ON menu_items FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "menu_items_update" ON menu_items FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "menu_items_delete" ON menu_items FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── SHIFTS ───────────────────────────────────────────────────
-- Select: owner lihat semua, admin/kasir hanya outlet sendiri
CREATE POLICY "shifts_select" ON shifts FOR SELECT USING (
  is_owner()
  OR outlet_id = auth_outlet_id()
);
-- Insert: owner bebas semua outlet; admin buka untuk outlet sendiri; kasir hanya untuk diri sendiri
CREATE POLICY "shifts_insert" ON shifts FOR INSERT WITH CHECK (
  is_owner()
  OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
  OR (outlet_id = auth_outlet_id() AND kasir_id = auth.uid())
);
-- Update: owner bebas semua; admin update shift di outlet sendiri; kasir hanya shift sendiri
CREATE POLICY "shifts_update" ON shifts FOR UPDATE USING (
  is_owner()
  OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
  OR (outlet_id = auth_outlet_id() AND kasir_id = auth.uid())
);

-- ── ORDERS ───────────────────────────────────────────────────
CREATE POLICY "orders_select" ON orders FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "orders_insert" ON orders FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
);
CREATE POLICY "orders_update" ON orders FOR UPDATE USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "orders_delete" ON orders FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── ORDER_ITEMS ──────────────────────────────────────────────
-- order_items tidak punya outlet_id langsung, join via orders
CREATE POLICY "order_items_select" ON order_items FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = order_items.order_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())
  )
);
CREATE POLICY "order_items_insert" ON order_items FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = order_items.order_id
      AND o.outlet_id = auth_outlet_id()
  )
);
CREATE POLICY "order_items_update" ON order_items FOR UPDATE USING (
  EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = order_items.order_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())
  )
);
CREATE POLICY "order_items_delete" ON order_items FOR DELETE USING (
  EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = order_items.order_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())
  )
);

-- ── PAYMENTS ─────────────────────────────────────────────────
CREATE POLICY "payments_select" ON payments FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "payments_insert" ON payments FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
);
CREATE POLICY "payments_update" ON payments FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── INGREDIENTS ──────────────────────────────────────────────
CREATE POLICY "ingredients_select" ON ingredients FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "ingredients_insert" ON ingredients FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "ingredients_update" ON ingredients FOR UPDATE USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "ingredients_delete" ON ingredients FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── STOCK_TRANSACTIONS ───────────────────────────────────────
CREATE POLICY "stock_tx_select" ON stock_transactions FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "stock_tx_insert" ON stock_transactions FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
);

-- ── PROMOS ───────────────────────────────────────────────────
CREATE POLICY "promos_select" ON promos FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "promos_insert" ON promos FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "promos_update" ON promos FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "promos_delete" ON promos FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── VOUCHERS ─────────────────────────────────────────────────
CREATE POLICY "vouchers_select" ON vouchers FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "vouchers_insert" ON vouchers FOR INSERT WITH CHECK (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "vouchers_update" ON vouchers FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── EXPENSES ─────────────────────────────────────────────────
CREATE POLICY "expenses_select" ON expenses FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()
);
CREATE POLICY "expenses_insert" ON expenses FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
);
CREATE POLICY "expenses_update" ON expenses FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
CREATE POLICY "expenses_delete" ON expenses FOR DELETE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── Views: grant SELECT ke authenticated ─────────────────────
GRANT SELECT ON v_daily_sales        TO authenticated;
GRANT SELECT ON v_top_menu_items     TO authenticated;
GRANT SELECT ON v_payment_summary    TO authenticated;
GRANT SELECT ON v_low_stock          TO authenticated;
GRANT SELECT ON v_profit_loss        TO authenticated;
GRANT SELECT ON v_kasir_performance  TO authenticated;

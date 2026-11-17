-- ============================================================
-- 008_customer_menu_anon.sql
-- Izinkan anon (customer scan QR) untuk baca menu & buat order
-- Jalankan sekali di Supabase Dashboard → SQL Editor
-- ============================================================

-- ── outlets: anon bisa baca info outlet (nama, settings) ──
CREATE POLICY "outlets_select_anon"
  ON outlets FOR SELECT TO anon
  USING (is_active = true);

-- ── restaurant_tables: anon bisa lookup by qr_token ────────
CREATE POLICY "tables_select_anon"
  ON restaurant_tables FOR SELECT TO anon
  USING (is_active = true);

-- ── menu_categories: anon bisa baca kategori aktif ─────────
CREATE POLICY "menu_categories_select_anon"
  ON menu_categories FOR SELECT TO anon
  USING (is_active = true);

-- ── menu_items: anon bisa baca item tersedia ────────────────
CREATE POLICY "menu_items_select_anon"
  ON menu_items FOR SELECT TO anon
  USING (is_available = true AND is_active = true);

-- ── orders: anon bisa insert self_order ────────────────────
CREATE POLICY "orders_insert_anon"
  ON orders FOR INSERT TO anon
  WITH CHECK (order_type = 'self_order');

-- ── Helper: cek self_order via SECURITY DEFINER (bypass RLS) ─
-- Diperlukan karena RLS anon memblokir SELECT ke tabel orders,
-- tapi WITH CHECK di order_items perlu verifikasi order tersebut.
CREATE OR REPLACE FUNCTION is_self_order(p_order_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM orders
    WHERE id = p_order_id AND order_type = 'self_order'
  )
$$;

-- ── order_items: anon bisa insert untuk self_order ─────────
CREATE POLICY "order_items_insert_anon"
  ON order_items FOR INSERT TO anon
  WITH CHECK (is_self_order(order_id));

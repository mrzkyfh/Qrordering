-- ============================================================
-- 056_fix_oio_anon_insert.sql
--
-- BUG (produksi): pelanggan web gagal "Kirim Pesanan" bila item punya EXTRAS:
--   ERROR: new row violates row-level security policy for table "order_item_options"
--
-- SEBAB: policy oio_insert_anon (migration 048) memakai sub-query
--   `EXISTS (SELECT 1 FROM order_items oi WHERE oi.id = ... AND is_self_order(...))`.
--   Sub-query `FROM order_items` itu TUNDUK RLS. Anon hanya punya policy INSERT
--   di order_items (008), TIDAK punya SELECT (policy SELECT 005 berbasis auth).
--   Jadi sub-query selalu kosong untuk anon → EXISTS false → insert ditolak.
--
-- FIX: cek lewat fungsi SECURITY DEFINER (bypass RLS) berdasar order_item_id,
--   sama pola dengan is_self_order() untuk tabel orders. Tidak bergantung pada
--   hak SELECT anon di order_items.
-- ============================================================

-- Helper: order_item milik order ber-tipe self_order? (bypass RLS via DEFINER)
CREATE OR REPLACE FUNCTION is_self_order_item(p_order_item_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    WHERE oi.id = p_order_item_id
      AND o.order_type = 'self_order'
  )
$$;

GRANT EXECUTE ON FUNCTION is_self_order_item(UUID) TO anon, authenticated;

-- Ganti policy anon untuk order_item_options agar tidak bergantung sub-query
-- ber-RLS.
DROP POLICY IF EXISTS "oio_insert_anon" ON order_item_options;
CREATE POLICY "oio_insert_anon" ON order_item_options
  FOR INSERT TO anon
  WITH CHECK (is_self_order_item(order_item_id));

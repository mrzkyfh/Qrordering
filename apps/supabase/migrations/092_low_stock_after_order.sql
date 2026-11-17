-- 092_low_stock_after_order.sql
-- FITUR NEW-3 — Alert stok menipis (proaktif).
-- Sebelumnya stok menipis hanya TAMPIL pasif (badge/hitungan). RPC ini memberi
-- app daftar bahan yang BARU menyentuh/melewati batas minimum AKIBAT order tsb,
-- sehingga kasir bisa langsung diberi tahu tepat setelah transaksi.
--
-- "Baru menipis" = bahan yang sebelum order ini masih di atas minimum
-- (qty_before > min) tapi kini sudah di batas/di bawah (stock_qty <= min).
-- Bahan yang memang sudah menipis dari sebelumnya tidak diulang alertnya.

CREATE OR REPLACE FUNCTION low_stock_after_order(p_order_id UUID)
RETURNS TABLE(name TEXT, stock_qty NUMERIC, min_stock_qty NUMERIC, unit TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT DISTINCT i.name, i.stock_qty, i.min_stock_qty, i.unit
  FROM ingredients i
  JOIN stock_transactions st
    ON st.ingredient_id = i.id
   AND st.order_id = p_order_id
   AND st.type = 'usage'
  WHERE i.min_stock_qty > 0
    AND i.stock_qty <= i.min_stock_qty          -- sekarang menipis
    AND st.qty_before > i.min_stock_qty         -- tadinya di atas minimum
    AND (public.is_owner() OR i.outlet_id = public.auth_outlet_id());
$$;

REVOKE ALL ON FUNCTION low_stock_after_order(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION low_stock_after_order(UUID) TO authenticated;

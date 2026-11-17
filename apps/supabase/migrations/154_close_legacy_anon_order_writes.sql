-- 154_close_legacy_anon_order_writes.sql
--
-- Customer menu sekarang selalu membuat pesanan melalui create_self_order(),
-- yang memvalidasi QR, harga, promo, pajak, batas spam, dan idempotensi di
-- server. Jalur INSERT tabel langsung dari versi awal tidak lagi dipakai dan
-- melewati sebagian pemeriksaan tersebut, jadi ditutup sepenuhnya.

DROP POLICY IF EXISTS "orders_insert_anon" ON public.orders;
DROP POLICY IF EXISTS "order_items_insert_anon" ON public.order_items;
DROP POLICY IF EXISTS "oio_insert_anon" ON public.order_item_options;

REVOKE INSERT, UPDATE, DELETE ON public.orders FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.order_items FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.order_item_options FROM anon;

-- Kedua helper hanya dibutuhkan policy INSERT anonim lama di atas. RPC
-- create_self_order berjalan sebagai function owner dan tidak memakainya.
REVOKE EXECUTE ON FUNCTION public.is_self_order(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.is_self_order_item(UUID)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.is_self_order(UUID) IS
  'Helper lama tanpa hak API. Customer order wajib melalui create_self_order.';
COMMENT ON FUNCTION public.is_self_order_item(UUID) IS
  'Helper lama tanpa hak API. Customer order wajib melalui create_self_order.';

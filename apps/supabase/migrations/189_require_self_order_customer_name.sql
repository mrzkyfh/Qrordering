-- Nama pelanggan wajib untuk setiap pesanan dari QR meja. Constraint dibuat
-- NOT VALID agar data historis tanpa nama tidak menggagalkan deployment, tetapi
-- PostgreSQL tetap menegakkannya untuk INSERT/UPDATE baru.

ALTER TABLE public.orders
  ADD CONSTRAINT orders_self_order_customer_name_required
  CHECK (
    order_type <> 'self_order'
    OR NULLIF(BTRIM(customer_name), '') IS NOT NULL
  ) NOT VALID;

COMMENT ON CONSTRAINT orders_self_order_customer_name_required
  ON public.orders IS
  'Pesanan QR baru wajib memiliki nama pelanggan yang tidak kosong.';

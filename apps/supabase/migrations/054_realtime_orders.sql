-- ============================================================
-- 054_realtime_orders.sql
-- Aktifkan Supabase Realtime untuk tabel `orders` (dan `order_items`).
--
-- Tanpa ini, `.stream()` di mobile (NotificationService & daftar order live)
-- tak pernah menerima event INSERT/UPDATE → notifikasi in-app "pesanan baru
-- dari web" tidak muncul. Realtime hanya menyiarkan tabel yang terdaftar di
-- publication `supabase_realtime`. RLS tetap berlaku (kasir hanya menerima
-- event untuk outlet-nya sendiri).
--
-- Aman dijalankan ulang.
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public' AND tablename = 'orders'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public' AND tablename = 'order_items'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.order_items;
  END IF;
END $$;

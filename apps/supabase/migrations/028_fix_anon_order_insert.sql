-- Fix: anon tidak bisa SELECT orders setelah insert karena tidak ada SELECT policy.
-- Solusi: client-side UUID sudah diperbaiki di app.js (tidak perlu .select('id') lagi).
-- Tapi is_self_order() butuh bisa SELECT orders → sudah SECURITY DEFINER, tidak perlu policy.
--
-- Tambahkan anon SELECT policy hanya untuk self_order milik mereka sendiri
-- agar error message lebih informatif (opsional, tidak blocking).

-- Tidak ada perubahan RLS yang diperlukan karena:
-- 1. app.js sudah generate UUID client-side, tidak perlu SELECT balik
-- 2. is_self_order() sudah SECURITY DEFINER (bypass RLS)
-- 3. order_items insert sudah bisa jalan via is_self_order()

-- Verifikasi is_self_order masih SECURITY DEFINER dengan search_path
CREATE OR REPLACE FUNCTION is_self_order(p_order_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM orders
    WHERE id = p_order_id AND order_type = 'self_order'
  );
$$;

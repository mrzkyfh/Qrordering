-- 123_table_token_capability.sql
-- qr_token adalah RAHASIA (kapabilitas), tapi selama ini bisa dibaca siapa pun.
--
-- MASALAH. Policy `tables_select_anon` (026) mengizinkan anon membaca SEMUA
-- baris restaurant_tables — termasuk kolom qr_token — untuk seluruh outlet.
-- Komentar migration 026 mengakuinya sendiri:
--
--     "BUG-ANON-001: Anon bisa enumerate semua meja semua outlet.
--      Fix: tetap izinkan SELECT tapi frontend WAJIB filter by qr_token.
--      RLS tidak bisa enforce filter query param..."
--
-- Itu bukan perbaikan — itu menuliskan kerentanannya sebagai sesuatu yang
-- diterima. RLS memang tak bisa memaksa klien menyaring; yang bisa adalah TIDAK
-- memberi klien barisnya sama sekali.
--
-- DAMPAK (terverifikasi di produksi): bermodal kunci anon — yang memang publik,
-- tertanam di customer-menu/app.js dan dikirim ke setiap pelanggan — satu
-- request tanpa autentikasi mengembalikan seluruh meja beserta qr_token-nya.
-- Dengan token itu siapa pun bisa memanggil create_self_order (di-grant ke anon)
-- untuk meja mana pun dari jarak jauh: dapur & kasir dibanjiri pesanan palsu.
-- Anti-spam (109) membatasi volumenya, tidak mencegah kemampuannya. Sekarang
-- baru 1 outlet; begitu multi-cabang, seluruh cabang ikut terekspos.
--
-- PERBAIKAN: pola kapabilitas — token DITUKAR lewat RPC, bukan dibaca sebagai
-- kolom. Pemanggil harus SUDAH memegang token untuk mendapat barisnya, jadi
-- tidak ada lagi enumerasi. Pola yang sama sudah dipakai get_self_orders (109):
-- "id acak = kapabilitas".

-- ── 1. RPC penukar token ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_table_by_token(p_token TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id',           t.id,
    'table_number', t.table_number,
    'area',         t.area,
    'outlet_id',    t.outlet_id,
    'is_active',    t.is_active
  )
  FROM restaurant_tables t
  JOIN outlets o ON o.id = t.outlet_id
  WHERE t.qr_token = p_token
    AND t.is_active = true
    AND o.is_active = true
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.resolve_table_by_token(TEXT) IS
  'Tukar qr_token dengan data meja. Token = kapabilitas: pemanggil harus sudah '
  'memegangnya. Menggantikan SELECT anon atas restaurant_tables, yang dulu '
  'membocorkan seluruh meja & token semua outlet ke siapa pun.';

REVOKE ALL ON FUNCTION public.resolve_table_by_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_table_by_token(TEXT) TO anon, authenticated;

-- ── 2. Cabut SELECT anon atas restaurant_tables ──────────────────────────────
-- Setelah ini anon TIDAK bisa lagi membaca tabelnya langsung — satu-satunya
-- jalan adalah RPC di atas, yang menuntut token.
--
-- Staf (authenticated) TIDAK terpengaruh: policy tenant-scoped mereka dari 048
-- tetap utuh, dan mereka memang perlu melihat daftar meja outletnya.
DROP POLICY IF EXISTS "tables_select_anon" ON restaurant_tables;

-- GRANT tabel-level juga dicabut agar tidak ada policy baru yang tak sengaja
-- membukanya lagi untuk anon.
REVOKE SELECT ON restaurant_tables FROM anon;

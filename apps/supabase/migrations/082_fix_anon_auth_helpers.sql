-- ============================================================
-- 082_fix_anon_auth_helpers.sql
-- FIX REGRESI: migration 069 mencabut EXECUTE auth helper dari anon
-- (auth_outlet_id, auth_role, auth_rank, is_owner). Padahal fungsi-fungsi ini
-- dipakai di policy RLS bertarget `public` (tables_select, outlets, menu_*, dll)
-- yang JUGA dievaluasi untuk anon. Akibatnya setiap query anon (customer-menu
-- scan QR: restaurant_tables/menu/outlets) gagal dengan:
--   ERROR 42501: permission denied for function auth_outlet_id
-- → halaman E-Menu selalu "QR code tidak valid atau meja tidak aktif".
--
-- Aman: untuk anon (tanpa JWT) fungsi ini mengembalikan NULL/false, jadi RLS
-- tetap menolak akses lintas-outlet. Memberi EXECUTE hanya agar evaluasi policy
-- tidak melempar error.
-- ============================================================

GRANT EXECUTE ON FUNCTION auth_outlet_id() TO anon;
GRANT EXECUTE ON FUNCTION auth_role()      TO anon;
GRANT EXECUTE ON FUNCTION auth_rank()      TO anon;
GRANT EXECUTE ON FUNCTION is_owner()       TO anon;

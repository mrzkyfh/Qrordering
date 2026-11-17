-- ============================================================
-- 060_revoke_self_set_pin.sql
-- PIN tidak lagi boleh diatur sendiri oleh staf.
-- Hanya owner/admin yang menetapkan PIN (admin_set_user_pin, lihat 059).
--
-- Cabut hak eksekusi set_my_pin dari user terautentikasi. RPC verify_my_pin
-- & has_my_pin tetap tersedia (untuk verifikasi saat refund).
-- ============================================================

REVOKE EXECUTE ON FUNCTION set_my_pin(TEXT) FROM authenticated;

-- 127_revoke_orphan_rpcs.sql
-- Cabut RPC YATIM yang masih ter-grant: dipanggil NOL klien, tapi tetap menganga
-- ke setiap staf yang login. Permukaan serang tanpa satu pun manfaat.
--
-- Ditemukan lewat sapuan: untuk tiap fungsi yang di-GRANT ke anon/authenticated,
-- dicari pemanggilnya di mobile, owner-panel, customer-menu, dan edge function.
-- Yang di bawah ini tak punya pemanggil sama sekali — dan tak dipakai internal
-- oleh policy/trigger mana pun.
--
-- ══ restore_menu_item & restore_ingredient (037) ═════════════════════════════
-- Keduanya SECURITY DEFINER (menembus RLS) dengan NOL pemeriksaan wewenang:
--
--     CREATE FUNCTION restore_menu_item(p_id UUID) ... SECURITY DEFINER AS $$
--     BEGIN
--       UPDATE menu_items SET is_active = true, is_available = true
--         WHERE id = p_id;   -- ← tanpa cek peran, tanpa scoping outlet
--
-- Tidak ada is_owner(), tidak ada auth_outlet_id(). Ter-grant ke SEMUA
-- authenticated (069). Artinya kasir di outlet A bisa mengaktifkan kembali menu
-- atau bahan yang sudah dihapus di outlet B — cukup dengan menebak/tahu id-nya.
-- Isolasi tenant bocor, dan aksinya tak terekam siapa pelakunya.
--
-- Komentar 069 sendiri mengklaim sebaliknya:
--     "delete/restore staff & outlet: hanya authenticated (sudah ada cek role
--      di dalam fungsi)"
-- Klaim itu benar untuk delete_* (yang memang memeriksa), tapi SALAH untuk
-- restore_* — keduanya tak punya cek apa pun. Klaim itulah yang membuat lubang
-- ini tampak sudah beres.
--
-- ══ increment_promo_usage (026/108) ═════════════════════════════════════════
-- Menaikkan promos.usage_count tanpa cek wewenang dan TANPA order nyata. Ini
-- persis serangan yang sudah ditutup untuk penerusnya — 074 mencabut
-- apply_promo_usage dari anon dengan alasan:
--     "Tanpa ini, siapapun bisa exhaust usage_count promo tanpa melakukan order."
-- dan 076 mewajibkan order_id nyata + idempotensi. Tapi fungsi LAMA-nya
-- dibiarkan ter-grant → jalan pintas yang membatalkan pengamanan itu. Siapa pun
-- yang login bisa menghabiskan kuota promo tanpa berbelanja.
--
-- ══ set_my_pin (047) & admin_set_user_pin (059) ═════════════════════════════
-- set_my_pin sudah dicabut 060 (staf tak boleh set PIN sendiri) — hanya sisa
-- kode. admin_set_user_pin adalah shim ke set_staff_pin; aman (hierarki dicek di
-- sana) tapi tak dipanggil siapa pun. Keduanya ikut dicabut agar permukaan RPC
-- mencerminkan yang benar-benar dipakai.
--
-- CATATAN: fungsinya sengaja TIDAK di-DROP, hanya dicabut hak eksekusinya.
-- delete_menu_item_smart/delete_ingredient_smart (yang DIPAKAI owner-panel)
-- kemungkinan mengandalkan restore_* untuk membatalkan penghapusan di kemudian
-- hari; membiarkan definisinya tetap ada membuat langkah ini mudah dibalik bila
-- ternyata ada yang membutuhkannya. Yang hilang hanya aksesnya dari luar.

REVOKE EXECUTE ON FUNCTION restore_menu_item(UUID)        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION restore_ingredient(UUID)       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION increment_promo_usage(UUID)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION set_my_pin(TEXT)               FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION admin_set_user_pin(UUID, TEXT) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION restore_menu_item(UUID) IS
  'YATIM — hak eksekusi dicabut (127). SECURITY DEFINER tanpa cek wewenang: '
  'siapa pun yang login bisa memulihkan menu outlet mana pun. Bila fitur '
  '"batalkan penghapusan" dibutuhkan, tambahkan cek is_owner()/auth_outlet_id() '
  'lebih dulu sebelum memberi grant lagi.';

COMMENT ON FUNCTION restore_ingredient(UUID) IS
  'YATIM — hak eksekusi dicabut (127). Alasan sama dengan restore_menu_item.';

COMMENT ON FUNCTION increment_promo_usage(UUID) IS
  'YATIM & DIGANTIKAN apply_promo_usage (076, wajib order_id nyata + idempoten). '
  'Hak eksekusi dicabut (127): fungsi ini menaikkan usage_count tanpa order, '
  'sehingga menjadi jalan pintas atas pengamanan yang dipasang 074/076.';

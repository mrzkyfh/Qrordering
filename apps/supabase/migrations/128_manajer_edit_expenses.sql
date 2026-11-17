-- 128_manajer_edit_expenses.sql
-- Manajer boleh MENYUNTING pengeluaran di outlet yang ia pegang (keputusan
-- pemilik). Menghapus tetap owner/admin saja.
--
-- ══ MASALAH: manajer bisa MEMBUAT pengeluaran, tapi tak bisa MEMPERBAIKINYA ══
--
-- Keadaan hari ini untuk manajer:
--   expenses_insert (107) : outlet_id = auth_outlet_id()  → BOLEH
--   expenses_update (005) : is_owner() OR (auth_role()='admin' AND ...) → DITOLAK
--   expenses_delete (005) : sama dengan update            → DITOLAK
--
-- Jadi manajer bisa mencatat pengeluaran lalu terkunci dari salah ketiknya
-- sendiri. Ia harus meminta admin/owner hanya untuk membetulkan satu angka.
--
-- Komentar 107 menyatakan "Manajer tetap tidak boleh insert (hanya admin/kasir
-- di outletnya)" — itu KELIRU: policy-nya `is_owner() OR outlet_id =
-- auth_outlet_id()` tidak memeriksa peran sama sekali, sehingga manajer selalu
-- boleh insert. Komentar itulah yang membuat asimetri ini luput: dibaca sekilas,
-- manajer tampak memang sengaja dijauhkan dari pengeluaran.
--
-- ══ KENAPA GAGALNYA TAK TERLIHAT ═════════════════════════════════════════════
--
-- owner-panel memberi manajer akses ke halaman /admin/expenses lengkap dengan
-- tombol Edit & Hapus (router: allowedRoles ['owner','admin','manajer']). Saat
-- manajer menyimpan, RLS MENYARING barisnya → 0 baris cocok → PostgREST membalas
-- 204 No Content, BUKAN error. useUpdateExpense hanya memeriksa `error`, jadi
-- UI-nya mengucap "tersimpan" dan daftar dimuat ulang tanpa perubahan apa pun.
-- Pola "RLS menyaring → 0 baris → terlihat sukses" yang sama sudah menggigit di
-- halaman setelan (113) dan trigger stok (124).
--
-- ══ PERBAIKAN ════════════════════════════════════════════════════════════════
--
-- expenses_update: tambahkan cabang manajer, scoped ke outletnya.
-- expenses_delete: SENGAJA tidak diubah — menghapus catatan keuangan tetap
-- wewenang owner/admin. Tombol Hapus juga disembunyikan dari manajer di UI,
-- supaya ia tak melihat tombol yang pasti gagal.
--
-- WITH CHECK tidak ditulis: untuk policy UPDATE, Postgres memakai ekspresi USING
-- sebagai WITH CHECK bila WITH CHECK dihilangkan. Jadi baris HASIL suntingan pun
-- wajib lolos syarat yang sama — manajer tak bisa memindahkan pengeluaran ke
-- outlet lain dengan mengganti outlet_id. Perilaku ini sama seperti sebelumnya
-- untuk admin; jangan menambahkan WITH CHECK yang lebih longgar di sini.
--
-- auth_role()/auth_outlet_id() mengembalikan NULL untuk staf NONAKTIF (122),
-- sehingga manajer yang dinonaktifkan otomatis ikut kehilangan hak ini.

DROP POLICY IF EXISTS "expenses_update" ON expenses;
CREATE POLICY "expenses_update" ON expenses
  FOR UPDATE TO authenticated
  USING (
    is_owner()
    OR (auth_role() = 'admin'   AND outlet_id = auth_outlet_id())
    OR (auth_role() = 'manajer' AND outlet_id = auth_outlet_id())   -- ◄ 128
  );

COMMENT ON TABLE expenses IS
  'Pengeluaran per outlet. Wewenang: owner penuh lintas-cabang; admin & manajer '
  'boleh tambah/sunting di outletnya sendiri; menghapus hanya owner/admin (128). '
  'Kasir boleh insert (107) tapi tidak menyunting.';

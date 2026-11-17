-- 126_owner_orders_and_loyalty_helpers.sql
-- Dua bug RLS yang lolos karena policy-nya tidak memakai helper standar.
--
-- ══ BUG 1: OWNER TIDAK BISA MEMBUAT ORDER ═══════════════════════════════════
--
-- orders_insert (080):
--     WITH CHECK (outlet_id = auth_outlet_id() AND status IN (...) AND ...)
-- Tidak ada cabang is_owner(). Ini PERSIS bug yang sudah diperbaiki 107 untuk
-- expenses, dengan penjelasannya sendiri:
--
--     "Owner bersifat lintas-cabang: profiles.outlet_id miliknya null (atau
--      menunjuk satu outlet saja), sehingga auth_outlet_id() tidak pernah sama
--      dengan outlet yang dipilih di owner-panel → INSERT selalu ditolak RLS."
--
-- Konsekuensinya di sini lebih berat daripada expenses: owner TIDAK BISA
-- BERTRANSAKSI SAMA SEKALI. Padahal aplikasi jelas mengharapkannya —
-- resolveCashTill menangani kasus "owner/admin (tanpa shift) → pilih till mana"
-- saat bayar tunai. Untuk owner ber-outlet_id tunggal, ia hanya bisa berjualan
-- di satu cabang dan ditolak di cabang lain.
--
-- Diperbaiki dengan pola yang sama persis dengan 107: `is_owner() OR ...`.
-- Guard lain (status & approved_by) dipertahankan utuh — hanya cabang owner
-- yang ditambahkan.

DROP POLICY IF EXISTS "orders_insert" ON orders;
CREATE POLICY "orders_insert" ON orders FOR INSERT WITH CHECK (
  (is_owner() OR outlet_id = auth_outlet_id())   -- ◄ 126 (pola 107)
  AND (status IS NULL OR status IN ('draft', 'confirmed'))
  AND (approved_by IS NULL)
);

-- ══ BUG 2: STAF NONAKTIF MASIH BISA MENYENTUH DATA LOYALTY ══════════════════
--
-- 122 menegakkan is_active di auth_role()/auth_outlet_id()/is_owner() supaya
-- SATU perubahan menutup seluruh permukaan RLS. Tapi policy loyalty (014)
-- MEM-BYPASS helper itu — ia menyalin lookup-nya sendiri:
--
--     outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
--     OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
--
-- Tanpa `AND is_active`, sehingga staf yang dinonaktifkan tetap bisa membaca &
-- menulis member + transaksi poin. Justru inilah alasan 122 memilih memperbaiki
-- helper: agar tak ada yang bisa lupa. Policy yang menyalin logikanya sendiri
-- membatalkan jaminan itu — jadi keduanya diarahkan kembali ke helper.
--
-- Perilaku untuk staf AKTIF tidak berubah: auth_outlet_id() mengembalikan
-- outlet yang sama, is_owner() mengenali owner yang sama.

DROP POLICY IF EXISTS "loyalty_members_crud" ON loyalty_members;
CREATE POLICY "loyalty_members_crud" ON loyalty_members
  FOR ALL TO authenticated
  USING       (is_owner() OR outlet_id = auth_outlet_id())   -- ◄ 126
  WITH CHECK  (is_owner() OR outlet_id = auth_outlet_id());

-- loyalty_transactions: HANYA select & insert yang diarahkan ke helper.
--
-- JANGAN membuat ulang policy FOR ALL di sini. 023 sengaja membuang
-- loyalty_txn_crud dan menggantinya dengan select+insert terpisah:
--     "loyalty_txn_crud menggunakan FOR ALL → admin/kasir bisa UPDATE dan
--      DELETE riwayat poin member (fraud risk, audit trail rusak).
--      ... Tidak ada UPDATE/DELETE policy → loyalty_transactions immutable"
-- Policy RLS bersifat OR: menambahkan satu policy FOR ALL akan MENGEMBALIKAN
-- hak UPDATE/DELETE pada buku besar poin yang sengaja dibuat tak bisa diubah.
DROP POLICY IF EXISTS "loyalty_txn_select" ON loyalty_transactions;
CREATE POLICY "loyalty_txn_select" ON loyalty_transactions FOR SELECT USING (
  is_owner() OR outlet_id = auth_outlet_id()                 -- ◄ 126
);

DROP POLICY IF EXISTS "loyalty_txn_insert" ON loyalty_transactions;
CREATE POLICY "loyalty_txn_insert" ON loyalty_transactions FOR INSERT WITH CHECK (
  is_owner() OR outlet_id = auth_outlet_id()                 -- ◄ 126
);
-- Tetap TANPA policy UPDATE/DELETE → ledger poin tetap immutable (023).

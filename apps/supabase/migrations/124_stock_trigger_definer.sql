-- 124_stock_trigger_definer.sql
-- Trigger stok harus selalu berhasil menerapkan mutasinya — apa pun peran
-- pemasok barisnya. Sekaligus memulihkan hardening search_path yang hilang.
--
-- MASALAH 1 — RANJAU: gagal diam-diam.
-- `stock_tx_insert` (020) mengizinkan staf MANA PUN di outlet menyisipkan
-- stock_transactions:
--     WITH CHECK (is_owner() OR outlet_id = auth_outlet_id())
-- Tapi `ingredients_update` (022) hanya owner/admin:
--     USING (is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id()))
-- Dan apply_stock_transaction BUKAN SECURITY DEFINER → UPDATE-nya berjalan
-- sebagai PEMANGGIL. Bila kasir menyisipkan transaksi (mis. mencatat waste),
-- UPDATE ingredients disaring RLS → cocok 0 baris → TIDAK melempar error.
-- Hasilnya: transaksi tercatat di buku besar, stoknya tidak pernah berkurang,
-- dan tak ada yang tahu. Pola "RLS menyaring → 0 baris → terlihat sukses" yang
-- sama sudah menggigit di halaman setelan (lihat 113).
--
-- Hari ini belum terpicu: mobile tak pernah menulis stock_transactions langsung
-- dan owner-panel lewat RPC adjust_stock (SECURITY DEFINER, sehingga trigger
-- berjalan sebagai pemilik fungsi). Jadi ini ranjau, bukan kebakaran — tapi
-- begitu ada fitur "catat waste" di HP kasir, stok diam-diam berhenti akurat.
--
-- Perbaikan: buku besarnya yang dijaga (policy INSERT), bukan kemampuan trigger
-- menerapkannya. Sebuah baris stock_transactions yang SAH menurut RLS harus
-- selalu benar-benar memindahkan stok.
--
-- MASALAH 2 — hardening hilang tanpa suara.
-- 061 mengeraskan search_path fungsi ini lewat ALTER FUNCTION. Migration 100
-- lalu meng-CREATE OR REPLACE tanpa klausa SET search_path → hardening itu
-- terhapus diam-diam (jebakan yang sama sudah menggigit beberapa kali di repo
-- ini). Dikembalikan di sini — dan kini wajib, karena fungsinya jadi
-- SECURITY DEFINER.
--
-- Salinan setia 100 — hanya baris tanda tangan yang berubah.

CREATE OR REPLACE FUNCTION apply_stock_transaction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER                       -- ◄ 124
SET search_path = public, extensions   -- ◄ 124 (pulihkan hardening 061)
AS $$
BEGIN
  IF NEW.type IN ('purchase', 'return') THEN
    UPDATE ingredients
    SET stock_qty = stock_qty + NEW.qty, updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type = 'adjustment' THEN
    -- Dua-arah: koreksi bisa naik/turun. Magnitudo = qty (CHECK qty>0 aman).
    UPDATE ingredients
    SET stock_qty = stock_qty + (NEW.qty_after - NEW.qty_before), updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type IN ('usage', 'waste') THEN
    UPDATE ingredients
    SET stock_qty = stock_qty - NEW.qty, updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION apply_stock_transaction() IS
  'Terapkan mutasi stok dari baris stock_transactions ke ingredients.stock_qty. '
  'SECURITY DEFINER: wewenang dijaga di policy INSERT stock_transactions — baris '
  'yang sah menurut RLS harus SELALU benar-benar memindahkan stok. Tanpa ini, '
  'insert oleh kasir gagal menyentuh ingredients (RLS) tanpa error: buku besar '
  'terisi, stok tidak berubah.';

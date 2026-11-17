-- ============================================================
-- 064_role_manajer.sql
-- Tambah role baru 'manajer' pada enum user_role.
--
-- Hierarki: owner > admin > manajer > kasir (dapur selevel kasir).
-- CATATAN: ALTER TYPE ... ADD VALUE tidak boleh dipakai di transaksi yang
-- sama dengan penambahannya → role 'manajer' baru dipakai mulai migrasi 065.
-- ============================================================

ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'manajer' AFTER 'admin';

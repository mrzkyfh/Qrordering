-- ============================================================
-- 011_menu_items_updated_at.sql
--
-- BUG: menu_items dibuat tanpa kolom updated_at (migration 002),
-- tapi migration 004 sudah pasang trigger trg_menu_items_updated_at
-- yang mencoba SET NEW.updated_at = NOW().
-- Setiap UPDATE (edit / soft-delete) pada menu_items gagal dengan:
--   "record "new" has no field "updated_at""
--
-- FIX: tambahkan kolom yang hilang, isi nilai awal dari created_at
-- jika kolom tersebut ada, atau NOW() sebagai fallback.
-- ============================================================

ALTER TABLE menu_items
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

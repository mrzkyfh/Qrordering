-- ============================================================
-- 067_add_void_reason.sql
-- Tambah kolom void_reason di orders.
--
-- void_order_with_approval (065) menulis void_reason, tetapi kolomnya tidak
-- pernah dibuat (035 hanya menambah voided_by/voided_at). Akibatnya void gagal:
-- 'column "void_reason" of relation "orders" does not exist' (42703).
-- ============================================================

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS void_reason TEXT;

COMMENT ON COLUMN orders.void_reason IS 'Alasan void order (status = void).';

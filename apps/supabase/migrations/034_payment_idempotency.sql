-- ============================================================
-- 034_payment_idempotency.sql
-- Tambah idempotency untuk payments — prevent double-charge
-- saat user tap "Bayar" 2x atau network retry.
--
-- Client mobile generate UUID v4 sebelum submit, server reject
-- duplikat via UNIQUE constraint partial.
-- ============================================================

ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT;

-- Partial unique: hanya validasi kalau key di-supply (nullable untuk back-compat)
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_idem
  ON payments (order_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

COMMENT ON COLUMN payments.idempotency_key IS
  'UUID dari client untuk prevent double-charge. NULL = legacy/external payment.';

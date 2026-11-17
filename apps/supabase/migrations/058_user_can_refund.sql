-- ============================================================
-- 058_user_can_refund.sql
-- Hak akses REFUND per user (dikelola owner/admin via dashboard).
--
-- - Kolom can_refund di profiles (default TRUE → non-breaking).
-- - Trigger enforce server-side: user tanpa izin tidak bisa mengubah
--   order menjadi 'cancelled' (refund). Tidak menyentuh 'void'.
--   Konteks server/service-role (auth.uid() NULL) tidak dibatasi.
-- ============================================================

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS can_refund BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN profiles.can_refund IS
  'Izin melakukan refund (order → cancelled, dengan PIN). Dikelola owner/admin. Default TRUE.';

-- ── Penegak izin refund (server-side) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION enforce_refund_permission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Hanya saat transisi menjadi 'cancelled' (refund) oleh user terautentikasi.
  IF NEW.status = 'cancelled'
     AND OLD.status IS DISTINCT FROM 'cancelled'
     AND auth.uid() IS NOT NULL THEN
    IF NOT COALESCE(
        (SELECT can_refund FROM profiles WHERE id = auth.uid()), FALSE) THEN
      RAISE EXCEPTION 'Anda tidak memiliki izin untuk melakukan refund';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_refund_permission ON orders;
CREATE TRIGGER trg_enforce_refund_permission
  BEFORE UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION enforce_refund_permission();

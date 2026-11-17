-- ============================================================
-- 035_order_void_audit.sql
-- Audit trail untuk void order — siapa & kapan
--
-- Sebelumnya: hanya `void_reason` yang terekam.
-- Sekarang: void_by + voided_at + void_reason lengkap.
-- ============================================================

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS voided_by  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS voided_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_orders_voided_by ON orders(voided_by) WHERE voided_by IS NOT NULL;

-- Trigger: saat status berubah jadi 'void', auto-set voided_at & voided_by
CREATE OR REPLACE FUNCTION set_order_void_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND NEW.status = 'void' AND
      (OLD.status IS DISTINCT FROM 'void')) THEN
    NEW.voided_at := COALESCE(NEW.voided_at, NOW());
    NEW.voided_by := COALESCE(NEW.voided_by, auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_void_audit ON orders;
CREATE TRIGGER trg_order_void_audit
  BEFORE UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION set_order_void_audit();

COMMENT ON COLUMN orders.voided_by IS 'User UUID yang melakukan void. Auto-set dari auth.uid() via trigger.';
COMMENT ON COLUMN orders.voided_at IS 'Timestamp saat void. Auto-set via trigger.';

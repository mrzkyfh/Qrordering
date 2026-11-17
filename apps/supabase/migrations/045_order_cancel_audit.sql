-- ============================================================
-- 045_order_cancel_audit.sql
-- Audit trail untuk cancel order (mirror 035_order_void_audit untuk status='cancelled').
-- Dipakai oleh halaman Laporan Refund.
-- ============================================================

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_orders_cancelled_by ON orders(cancelled_by) WHERE cancelled_by IS NOT NULL;

CREATE OR REPLACE FUNCTION set_order_cancel_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND NEW.status = 'cancelled' AND
      (OLD.status IS DISTINCT FROM 'cancelled')) THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, NOW());
    NEW.cancelled_by := COALESCE(NEW.cancelled_by, auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_cancel_audit ON orders;
CREATE TRIGGER trg_order_cancel_audit
  BEFORE UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION set_order_cancel_audit();

-- Backfill: order yang sudah cancelled tapi belum punya cancelled_at → pakai updated_at
UPDATE orders
SET cancelled_at = updated_at
WHERE status = 'cancelled' AND cancelled_at IS NULL;

COMMENT ON COLUMN orders.cancelled_by IS 'User UUID yang melakukan cancel. Auto-set dari auth.uid() via trigger.';
COMMENT ON COLUMN orders.cancelled_at IS 'Timestamp saat cancel. Auto-set via trigger.';
-- ============================================================
-- 057_allow_served_refund.sql
--
-- Izinkan REFUND (status → cancelled) untuk order yang sudah DISAJIKAN
-- (status 'served') — termasuk order yang belum lunas. Sebelumnya validator
-- (025 → 055) hanya mengizinkan served → paid / void, sehingga refund order
-- "selesai" ditolak: invalid order status transition: served → cancelled.
--
-- Saat → 'cancelled':
--   • trg_order_stock (009) memanggil restore_stock_for_order() → stok kembali
--   • trg_order_cancel_audit (045) mengisi cancelled_by / cancelled_at
--   • Laporan Refund menghitungnya
-- ============================================================

CREATE OR REPLACE FUNCTION validate_order_status_transition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  valid_next TEXT[];
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  CASE OLD.status
    WHEN 'draft'     THEN valid_next := ARRAY['confirmed','cancelled','void'];
    WHEN 'confirmed' THEN valid_next := ARRAY['preparing','cancelled','void'];
    WHEN 'preparing' THEN valid_next := ARRAY['ready','cancelled','void'];
    WHEN 'ready'     THEN valid_next := ARRAY['served','cancelled','void'];
    WHEN 'served'    THEN valid_next := ARRAY['paid','void','cancelled']; -- + refund
    WHEN 'paid'      THEN valid_next := ARRAY['cancelled','void']; -- refund / void lunas
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % → %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

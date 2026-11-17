-- ============================================================
-- 055_allow_paid_refund.sql
--
-- BUG: Refund transaksi yang SUDAH dibayar gagal.
--   validate_order_status_transition() (migration 025) tidak punya
--   aturan untuk OLD.status = 'paid' → jatuh ke ELSE (array kosong),
--   sehingga `paid → cancelled` (refund) maupun `paid → void` ditolak:
--     ERROR: invalid order status transition: paid → cancelled
--
-- FIX: Izinkan dari 'paid' menuju 'cancelled' (refund) atau 'void'.
--   Saat status → 'cancelled':
--     • trg_order_stock (009) memanggil restore_stock_for_order() → stok kembali
--     • trg_order_cancel_audit (045) mengisi cancelled_by / cancelled_at
--     • Laporan Refund/Kas menghitungnya sebagai refund
--   Status 'cancelled' & 'void' tetap terminal (ELSE = array kosong).
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
    WHEN 'served'    THEN valid_next := ARRAY['paid','void'];
    WHEN 'paid'      THEN valid_next := ARRAY['cancelled','void']; -- refund / void transaksi lunas
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % → %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

-- Trigger trg_validate_order_status (025) tetap memakai fungsi ini —
-- cukup CREATE OR REPLACE di atas, tidak perlu drop/recreate trigger.

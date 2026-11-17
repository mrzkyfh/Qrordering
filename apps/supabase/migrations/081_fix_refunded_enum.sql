-- ============================================================
-- 081_fix_refunded_enum.sql
-- FIX: enum order_status TIDAK punya nilai 'refunded'. Beberapa objek keliru
-- memakainya → error 22P02 "invalid input value for enum order_status: refunded".
-- Dampak terparah: handle_order_stock_trigger membandingkan NEW.status terhadap
-- 'refunded' di SETIAP update status → pembayaran (→paid) gagal total.
--
-- Refund yang benar = status 'cancelled' (dicek oleh enforce_refund_permission).
-- Migration ini self-contained: jalankan 081 saja sudah memperbaiki semuanya.
-- ============================================================

-- 1. Trigger stok — buang 'refunded' (refund = 'cancelled').
CREATE OR REPLACE FUNCTION handle_order_stock_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status IN ('confirmed', 'preparing', 'paid')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM deduct_stock_for_order(NEW.id);
  END IF;
  IF NEW.status IN ('cancelled', 'void')
     AND OLD.status NOT IN ('cancelled', 'void') THEN
    PERFORM restore_stock_for_order(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

-- 2. State-machine — izinkan ->paid, dan paid->cancelled/void (untuk refund).
CREATE OR REPLACE FUNCTION validate_order_status_transition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  valid_next TEXT[];
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  CASE OLD.status
    WHEN 'draft'     THEN valid_next := ARRAY['confirmed','paid','cancelled','void'];
    WHEN 'confirmed' THEN valid_next := ARRAY['preparing','ready','served','paid','cancelled','void'];
    WHEN 'preparing' THEN valid_next := ARRAY['ready','served','paid','cancelled','void'];
    WHEN 'ready'     THEN valid_next := ARRAY['served','paid','cancelled','void'];
    WHEN 'served'    THEN valid_next := ARRAY['paid','cancelled','void'];
    WHEN 'paid'      THEN valid_next := ARRAY['cancelled','void']; -- refund/void setelah bayar
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

-- 3. RPC VOID — buang 'refunded' dari pengecekan status.
CREATE OR REPLACE FUNCTION public.void_order_with_approval(
  p_order        UUID,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_approver_id UUID; v_approver_name TEXT; v_outlet UUID; v_status order_status;
BEGIN
  IF p_approver_id IS NULL THEN RAISE EXCEPTION 'approver_id wajib diisi'; END IF;
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status = 'paid' THEN
    RAISE EXCEPTION 'Order sudah dibayar — gunakan Refund, bukan Void';
  END IF;
  IF v_status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan';
  END IF;
  SELECT _find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;
  IF v_approver_id IS NULL THEN RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'; END IF;
  SELECT full_name INTO v_approver_name FROM profiles WHERE id = v_approver_id;
  UPDATE orders
  SET status = 'void', void_reason = p_reason, approved_by = v_approver_id, updated_at = now()
  WHERE id = p_order;
  PERFORM restore_stock_for_order(p_order);
  RETURN QUERY SELECT v_approver_name;
END;
$$;

-- 4. RPC REFUND — set status 'cancelled' (bukan 'refunded' yang invalid).
CREATE OR REPLACE FUNCTION public.refund_order_with_approval(
  p_order        UUID,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_approver_id UUID; v_approver_name TEXT; v_outlet UUID; v_status order_status;
BEGIN
  IF p_approver_id IS NULL THEN RAISE EXCEPTION 'approver_id wajib diisi'; END IF;
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan refund';
  END IF;
  SELECT _find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;
  IF v_approver_id IS NULL THEN RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'; END IF;
  SELECT full_name INTO v_approver_name FROM profiles WHERE id = v_approver_id;
  UPDATE orders
  SET status = 'cancelled', void_reason = p_reason, approved_by = v_approver_id, updated_at = now()
  WHERE id = p_order;
  PERFORM restore_stock_for_order(p_order);
  RETURN QUERY SELECT v_approver_name;
END;
$$;

REVOKE ALL ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;

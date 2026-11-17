-- ============================================================
-- 025_business_logic_fixes.sql
-- Fix dari API testing business logic 2026-05-27
-- BUG-ORD-001..003, BUG-PROMO-001..002, BUG-VOC-001, BUG-BOUND-001..002
-- ============================================================

-- ── BUG-ORD-001 + BUG-ORD-002 ────────────────────────────────
-- Tidak ada state machine pada order status.
-- Status bisa mundur (paid→draft), skip (draft→paid), atau
-- item bisa ditambah ke order yang sudah closed.
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
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % → %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_order_status ON orders;
CREATE TRIGGER trg_validate_order_status
  BEFORE UPDATE OF status ON orders
  FOR EACH ROW EXECUTE FUNCTION validate_order_status_transition();

-- ── BUG-ORD-002 (item ke closed order) ───────────────────────
CREATE OR REPLACE FUNCTION validate_order_item_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status order_status;
BEGIN
  SELECT status INTO v_status FROM orders WHERE id = NEW.order_id;
  IF v_status NOT IN ('draft', 'confirmed') THEN
    RAISE EXCEPTION 'cannot add items to order with status: %', v_status;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_order_item_insert ON order_items;
CREATE TRIGGER trg_validate_order_item_insert
  BEFORE INSERT ON order_items
  FOR EACH ROW EXECUTE FUNCTION validate_order_item_insert();

-- ── BUG-ORD-003 ───────────────────────────────────────────────
-- Order amounts (subtotal, discount, tax, service, total) tidak boleh negatif.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_order_amounts'
  ) THEN
    ALTER TABLE orders ADD CONSTRAINT chk_order_amounts CHECK (
      subtotal >= 0
      AND discount_amount >= 0
      AND tax_amount >= 0
      AND service_charge >= 0
      AND total_amount >= 0
    );
  END IF;
END $$;

-- ── BUG-PROMO-001 + BUG-PROMO-002 ────────────────────────────
-- increment_promo_usage tidak memvalidasi usage_limit dan end_date.
CREATE OR REPLACE FUNCTION increment_promo_usage(p_promo_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_limit    INTEGER;
  v_count    INTEGER;
  v_end_date DATE;
BEGIN
  SELECT usage_limit, usage_count, end_date
  INTO v_limit, v_count, v_end_date
  FROM promos WHERE id = p_promo_id FOR UPDATE;

  IF v_end_date IS NOT NULL AND v_end_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'promo has expired';
  END IF;

  IF v_limit IS NOT NULL AND v_count >= v_limit THEN
    RAISE EXCEPTION 'promo usage limit reached';
  END IF;

  UPDATE promos
  SET usage_count = usage_count + 1, updated_at = NOW()
  WHERE id = p_promo_id;
END;
$$;

-- ── BUG-VOC-001 ──────────────────────────────────────────────
-- Voucher usage_count tidak ada DB constraint terhadap usage_limit.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_voucher_usage'
  ) THEN
    ALTER TABLE vouchers ADD CONSTRAINT chk_voucher_usage
      CHECK (usage_limit IS NULL OR usage_count <= usage_limit);
  END IF;
END $$;

-- ── BUG-BOUND-001 ─────────────────────────────────────────────
-- Profile full_name bisa empty string.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_profile_full_name'
  ) THEN
    ALTER TABLE profiles ADD CONSTRAINT chk_profile_full_name
      CHECK (char_length(trim(full_name)) > 0);
  END IF;
END $$;

-- ── BUG-BOUND-002 ─────────────────────────────────────────────
-- Shift opening_cash bisa negatif.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_shifts_cash'
  ) THEN
    ALTER TABLE shifts ADD CONSTRAINT chk_shifts_cash
      CHECK (opening_cash >= 0);
  END IF;
END $$;

-- ============================================================
-- 040_promo_validation_rpcs.sql
-- RPC untuk validasi dan klaim promo/voucher
-- Accessible oleh anon (customer menu) DAN authenticated (POS)
-- ============================================================

-- ── 1. validate_promo_code ───────────────────────────────────
-- Validates a voucher/promo code against outlet + subtotal.
-- Returns JSON with promo_id, voucher_id, discount_amount.
-- NO mutation — safe to call before final order submission.

CREATE OR REPLACE FUNCTION validate_promo_code(
  p_code      TEXT,
  p_outlet_id UUID,
  p_subtotal  NUMERIC
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher   vouchers%ROWTYPE;
  v_promo     promos%ROWTYPE;
  v_discount  NUMERIC;
BEGIN
  -- 1. Find voucher by code (case-insensitive)
  SELECT * INTO v_voucher
  FROM vouchers
  WHERE UPPER(TRIM(code)) = UPPER(TRIM(p_code))
    AND outlet_id = p_outlet_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kode voucher tidak ditemukan atau tidak aktif';
  END IF;

  -- 2. Check voucher individual usage limit
  IF v_voucher.usage_limit IS NOT NULL AND v_voucher.usage_count >= v_voucher.usage_limit THEN
    RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan';
  END IF;

  -- 3. Get associated promo
  SELECT * INTO v_promo FROM promos WHERE id = v_voucher.promo_id;

  IF NOT FOUND OR NOT v_promo.is_active THEN
    RAISE EXCEPTION 'Promo tidak aktif';
  END IF;

  -- 4. Validate promo date range
  IF v_promo.start_date IS NOT NULL AND CURRENT_DATE < v_promo.start_date THEN
    RAISE EXCEPTION 'Promo belum berlaku (mulai %)' , v_promo.start_date::TEXT;
  END IF;

  IF v_promo.end_date IS NOT NULL AND CURRENT_DATE > v_promo.end_date THEN
    RAISE EXCEPTION 'Promo sudah kedaluwarsa';
  END IF;

  -- 5. Validate promo global usage limit
  IF v_promo.usage_limit IS NOT NULL AND v_promo.usage_count >= v_promo.usage_limit THEN
    RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan total';
  END IF;

  -- 6. Validate minimum order amount
  IF p_subtotal < v_promo.min_order THEN
    RAISE EXCEPTION 'Minimum order Rp % untuk promo ini', TO_CHAR(v_promo.min_order, 'FM999,999,999');
  END IF;

  -- 7. Calculate discount amount
  IF v_promo.type = 'percentage' THEN
    v_discount := ROUND(p_subtotal * v_promo.value / 100, 0);
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := LEAST(v_discount, v_promo.max_discount);
    END IF;
  ELSIF v_promo.type = 'fixed' THEN
    v_discount := LEAST(v_promo.value, p_subtotal);
  ELSE
    -- bundling / bogo: tidak diimplementasikan sebagai diskon tunai
    v_discount := 0;
  END IF;

  RETURN json_build_object(
    'promo_id',       v_promo.id,
    'voucher_id',     v_voucher.id,
    'promo_name',     v_promo.name,
    'discount_amount', v_discount
  );
END;
$$;

REVOKE ALL ON FUNCTION validate_promo_code(TEXT, UUID, NUMERIC) FROM public;
GRANT EXECUTE ON FUNCTION validate_promo_code(TEXT, UUID, NUMERIC) TO anon;
GRANT EXECUTE ON FUNCTION validate_promo_code(TEXT, UUID, NUMERIC) TO authenticated;

-- ── 2. apply_promo_usage ─────────────────────────────────────
-- Atomically increments usage_count for promo AND its voucher.
-- Call ONCE after order is successfully created/paid.
-- SECURITY DEFINER so anon (customer menu) can increment.

CREATE OR REPLACE FUNCTION apply_promo_usage(
  p_promo_id   UUID,
  p_voucher_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_promo_limit    INTEGER;
  v_promo_count    INTEGER;
  v_promo_end_date DATE;
  v_voucher_limit  INTEGER;
  v_voucher_count  INTEGER;
BEGIN
  -- Re-validate promo before incrementing (atomic check-and-set)
  SELECT usage_limit, usage_count, end_date
  INTO v_promo_limit, v_promo_count, v_promo_end_date
  FROM promos WHERE id = p_promo_id FOR UPDATE;

  IF v_promo_end_date IS NOT NULL AND v_promo_end_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'Promo sudah kedaluwarsa';
  END IF;

  IF v_promo_limit IS NOT NULL AND v_promo_count >= v_promo_limit THEN
    RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan';
  END IF;

  UPDATE promos
  SET usage_count = usage_count + 1, updated_at = NOW()
  WHERE id = p_promo_id;

  -- Increment voucher usage if provided
  IF p_voucher_id IS NOT NULL THEN
    SELECT usage_limit, usage_count
    INTO v_voucher_limit, v_voucher_count
    FROM vouchers WHERE id = p_voucher_id FOR UPDATE;

    IF v_voucher_limit IS NOT NULL AND v_voucher_count >= v_voucher_limit THEN
      RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan';
    END IF;

    UPDATE vouchers
    SET usage_count = usage_count + 1
    WHERE id = p_voucher_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION apply_promo_usage(UUID, UUID) FROM public;
GRANT EXECUTE ON FUNCTION apply_promo_usage(UUID, UUID) TO anon;
GRANT EXECUTE ON FUNCTION apply_promo_usage(UUID, UUID) TO authenticated;
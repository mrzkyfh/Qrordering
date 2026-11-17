-- ============================================================
-- 043_loyalty_redeem.sql
-- Loyalty redeem: pelanggan tukar poin jadi diskon saat checkout.
--
-- Konvensi redeem rate: outlets.loyalty_settings.redeem_rate menyatakan
-- jumlah poin yang diperlukan untuk Rp 1 diskon.
--   redeem_rate = 1   →  1 poin = Rp 1
--   redeem_rate = 100 →  100 poin = Rp 1 (poin susah ditukar)
--   redeem_rate = 0.1 →  1 poin = Rp 10
--
-- Formula: discount_rupiah = floor(points / redeem_rate)
-- ============================================================

-- ── 1. Kolom orders untuk redeem ─────────────────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS loyalty_discount NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS redeemed_points  INTEGER       NOT NULL DEFAULT 0;

ALTER TABLE orders
  ADD CONSTRAINT chk_loyalty_discount_non_negative CHECK (loyalty_discount >= 0),
  ADD CONSTRAINT chk_redeemed_points_non_negative  CHECK (redeemed_points >= 0);

-- ── 2. validate_loyalty_redeem ───────────────────────────────
-- Cek apakah member punya cukup poin, return discount Rp yang valid.
-- TIDAK memutasi saldo. Aman untuk preview di UI.

CREATE OR REPLACE FUNCTION validate_loyalty_redeem(
  p_member_id      UUID,
  p_points         INTEGER,
  p_subtotal       NUMERIC,
  p_promo_discount NUMERIC DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member       loyalty_members%ROWTYPE;
  v_settings     JSONB;
  v_redeem_rate  NUMERIC;
  v_discount     NUMERIC;
  v_cap          NUMERIC;
  v_effective_pt INTEGER;
BEGIN
  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'Jumlah poin yang ditukar harus > 0';
  END IF;

  SELECT * INTO v_member FROM loyalty_members WHERE id = p_member_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Member tidak ditemukan';
  END IF;

  IF v_member.points < p_points THEN
    RAISE EXCEPTION 'Saldo poin tidak cukup (tersedia: %)', v_member.points;
  END IF;

  -- Ambil redeem_rate dari outlet settings
  SELECT loyalty_settings INTO v_settings FROM outlets WHERE id = v_member.outlet_id;
  v_redeem_rate := COALESCE((v_settings->>'redeem_rate')::NUMERIC, 1);

  IF v_redeem_rate <= 0 THEN
    RAISE EXCEPTION 'Konfigurasi redeem_rate outlet tidak valid';
  END IF;

  v_discount := FLOOR(p_points / v_redeem_rate);

  -- Cap: tidak boleh melebihi (subtotal - promo_discount)
  v_cap := GREATEST(0, COALESCE(p_subtotal, 0) - COALESCE(p_promo_discount, 0));
  IF v_discount > v_cap THEN
    v_discount     := v_cap;
    v_effective_pt := FLOOR(v_cap * v_redeem_rate)::INTEGER;
  ELSE
    v_effective_pt := p_points;
  END IF;

  RETURN json_build_object(
    'member_id',          v_member.id,
    'discount_amount',    v_discount,
    'points_used',        v_effective_pt,
    'remaining_points',   v_member.points - v_effective_pt
  );
END;
$$;

REVOKE ALL ON FUNCTION validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC) FROM public;
GRANT EXECUTE ON FUNCTION validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC) TO anon, authenticated;

-- ── 3. redeem_loyalty_points ─────────────────────────────────
-- Atomik: catat transaksi redeem, kurangi saldo, set kolom orders.
-- Idempoten per order_id (cek loyalty_transactions type='redeem').
-- Re-validasi: tidak pakai discount dari client, hitung ulang dari points.

CREATE OR REPLACE FUNCTION redeem_loyalty_points(
  p_order_id  UUID,
  p_member_id UUID,
  p_points    INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order        orders%ROWTYPE;
  v_member       loyalty_members%ROWTYPE;
  v_settings     JSONB;
  v_redeem_rate  NUMERIC;
  v_discount     NUMERIC;
  v_existing_id  UUID;
BEGIN
  -- Idempotency
  SELECT id INTO v_existing_id
  FROM loyalty_transactions
  WHERE order_id = p_order_id AND type = 'redeem'
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN 0;
  END IF;

  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'Jumlah poin yang ditukar harus > 0';
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;

  SELECT * INTO v_member FROM loyalty_members WHERE id = p_member_id FOR UPDATE;
  IF NOT FOUND OR v_member.outlet_id != v_order.outlet_id THEN
    RAISE EXCEPTION 'Member tidak valid untuk outlet ini';
  END IF;

  IF v_member.points < p_points THEN
    RAISE EXCEPTION 'Saldo poin tidak cukup';
  END IF;

  -- Hitung discount dari sumber kebenaran (server-side)
  SELECT loyalty_settings INTO v_settings FROM outlets WHERE id = v_order.outlet_id;
  v_redeem_rate := COALESCE((v_settings->>'redeem_rate')::NUMERIC, 1);
  v_discount    := FLOOR(p_points / v_redeem_rate);

  -- Catat transaksi (negative points)
  INSERT INTO loyalty_transactions (member_id, outlet_id, order_id, type, points, description)
  VALUES (
    p_member_id, v_order.outlet_id, p_order_id, 'redeem', -p_points,
    'Redeem ' || p_points || ' poin → diskon Rp ' || v_discount::TEXT
      || ' untuk order #' || v_order.order_number
  );

  -- Kurangi saldo member
  UPDATE loyalty_members
  SET points = points - p_points
  WHERE id = p_member_id;

  -- Set kolom orders dengan nilai yang dihitung server (override apapun yang di-insert client)
  UPDATE orders
  SET loyalty_discount = v_discount,
      redeemed_points  = p_points,
      loyalty_member_id = COALESCE(loyalty_member_id, p_member_id)
  WHERE id = p_order_id;

  RETURN v_discount;
END;
$$;

REVOKE ALL ON FUNCTION redeem_loyalty_points(UUID, UUID, INTEGER) FROM public;
GRANT EXECUTE ON FUNCTION redeem_loyalty_points(UUID, UUID, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION redeem_loyalty_points(UUID, UUID, INTEGER) IS
  'Tukar poin loyalty menjadi diskon. Atomik & idempoten per order. '
  'Discount dihitung server-side dari outlets.loyalty_settings.redeem_rate.';

-- ── 4. Update view v_order_hpp (re-create karena column orders bertambah)
--    Tidak perlu — v_order_hpp tidak select kolom baru.

-- ── 5. Update earn RPC agar tidak earn dari nilai yang sudah di-redeem ──
-- (Opsional kebijakan bisnis: earn dari subtotal apa adanya — keep as-is)
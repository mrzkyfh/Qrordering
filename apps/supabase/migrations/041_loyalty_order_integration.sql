-- ============================================================
-- 041_loyalty_order_integration.sql
-- Integrasi loyalty ke order flow:
--   - kolom orders.loyalty_member_id
--   - RPC find_loyalty_member_by_phone (lookup, anon-callable)
--   - RPC award_loyalty_points (earn otomatis saat order paid)
-- ============================================================

-- ── 1. Kolom referensi member di orders ──────────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS loyalty_member_id UUID
  REFERENCES loyalty_members(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_orders_loyalty_member
  ON orders(loyalty_member_id)
  WHERE loyalty_member_id IS NOT NULL;

-- ── 2. RPC find_loyalty_member_by_phone ──────────────────────
-- Lookup member by phone untuk outlet tertentu.
-- Return NULL jika tidak ditemukan (bukan exception, agar UI mudah handle).

CREATE OR REPLACE FUNCTION find_loyalty_member_by_phone(
  p_phone     TEXT,
  p_outlet_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member loyalty_members%ROWTYPE;
BEGIN
  SELECT * INTO v_member
  FROM loyalty_members
  WHERE outlet_id = p_outlet_id
    AND phone     = TRIM(p_phone)
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'id',     v_member.id,
    'phone',  v_member.phone,
    'name',   v_member.name,
    'points', v_member.points,
    'tier',   v_member.tier
  );
END;
$$;

REVOKE ALL ON FUNCTION find_loyalty_member_by_phone(TEXT, UUID) FROM public;
GRANT EXECUTE ON FUNCTION find_loyalty_member_by_phone(TEXT, UUID) TO anon, authenticated;

-- ── 3. RPC award_loyalty_points ──────────────────────────────
-- Earn point otomatis saat order paid.
-- Idempoten: skip jika sudah ada transaksi earn untuk order_id ini.
-- Earn rate diambil dari outlets.loyalty_settings.points_per_rupiah.

CREATE OR REPLACE FUNCTION award_loyalty_points(
  p_order_id  UUID,
  p_member_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order         orders%ROWTYPE;
  v_settings      JSONB;
  v_rate          NUMERIC;
  v_points        INTEGER;
  v_existing_id   UUID;
BEGIN
  -- Idempotency: cek apakah sudah pernah earn untuk order ini
  SELECT id INTO v_existing_id
  FROM loyalty_transactions
  WHERE order_id = p_order_id AND type = 'earn'
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN 0;
  END IF;

  -- Ambil order
  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- Validasi member milik outlet yang sama
  IF NOT EXISTS (
    SELECT 1 FROM loyalty_members
    WHERE id = p_member_id AND outlet_id = v_order.outlet_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Member tidak valid untuk outlet ini';
  END IF;

  -- Ambil rate dari outlet settings
  SELECT loyalty_settings INTO v_settings FROM outlets WHERE id = v_order.outlet_id;
  v_rate := COALESCE((v_settings->>'points_per_rupiah')::NUMERIC, 0);

  IF v_rate <= 0 THEN
    RETURN 0;
  END IF;

  -- Hitung poin: floor(subtotal × rate). Pakai subtotal (sebelum tax/service)
  -- agar tidak earn poin dari pajak/biaya layanan.
  v_points := FLOOR(v_order.subtotal * v_rate)::INTEGER;

  IF v_points <= 0 THEN
    RETURN 0;
  END IF;

  -- Catat transaksi earn
  INSERT INTO loyalty_transactions (member_id, outlet_id, order_id, type, points, description)
  VALUES (
    p_member_id, v_order.outlet_id, p_order_id, 'earn', v_points,
    'Earn dari order #' || v_order.order_number
  );

  -- Update saldo poin member
  UPDATE loyalty_members
  SET points = points + v_points
  WHERE id = p_member_id;

  -- Link order ke member (kalau belum)
  UPDATE orders
  SET loyalty_member_id = p_member_id
  WHERE id = p_order_id AND loyalty_member_id IS NULL;

  RETURN v_points;
END;
$$;

REVOKE ALL ON FUNCTION award_loyalty_points(UUID, UUID) FROM public;
GRANT EXECUTE ON FUNCTION award_loyalty_points(UUID, UUID) TO anon, authenticated;

COMMENT ON FUNCTION award_loyalty_points(UUID, UUID) IS
  'Earn poin loyalty untuk order paid. Idempoten per order_id. '
  'Rate diambil dari outlets.loyalty_settings.points_per_rupiah.';
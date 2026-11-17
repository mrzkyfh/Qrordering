-- 173_harden_loyalty_redemption_scope.sql
-- Batasi RPC loyalty ke pengguna POS yang terautentikasi dan outletnya.
-- Sebelumnya fungsi SECURITY DEFINER hanya memeriksa kecocokan outlet member
-- dengan order. UUID order/member yang bocor dapat dipakai pengguna
-- authenticated dari outlet lain untuk mengurangi saldo member.

CREATE OR REPLACE FUNCTION public.validate_loyalty_redeem(
  p_member_id UUID,
  p_points INTEGER,
  p_subtotal NUMERIC,
  p_promo_discount NUMERIC DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_member       public.loyalty_members%ROWTYPE;
  v_settings     JSONB;
  v_redeem_rate  NUMERIC;
  v_discount     NUMERIC;
  v_cap          NUMERIC;
  v_effective_pt INTEGER;
BEGIN
  IF auth.uid() IS NULL
     OR COALESCE(public.auth_role()::TEXT, '') NOT IN
          ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Hanya pengguna POS yang dapat memvalidasi penukaran poin'
      USING ERRCODE = '42501';
  END IF;
  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'Jumlah poin yang ditukar harus > 0';
  END IF;

  SELECT * INTO v_member
  FROM public.loyalty_members
  WHERE id = p_member_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Member tidak ditemukan';
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_member.outlet_id IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Member bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;
  IF v_member.points < p_points THEN
    RAISE EXCEPTION 'Saldo poin tidak cukup (tersedia: %)', v_member.points;
  END IF;

  SELECT loyalty_settings INTO v_settings
  FROM public.outlets WHERE id = v_member.outlet_id;
  v_redeem_rate := COALESCE((v_settings->>'redeem_rate')::NUMERIC, 1);
  IF v_redeem_rate <= 0 THEN
    RAISE EXCEPTION 'Konfigurasi redeem_rate outlet tidak valid';
  END IF;

  v_discount := FLOOR(p_points / v_redeem_rate);
  v_cap := GREATEST(0, COALESCE(p_subtotal, 0) - COALESCE(p_promo_discount, 0));
  IF v_discount > v_cap THEN
    v_discount := v_cap;
    v_effective_pt := FLOOR(v_cap * v_redeem_rate)::INTEGER;
  ELSE
    v_effective_pt := p_points;
  END IF;

  RETURN json_build_object(
    'member_id', v_member.id,
    'discount_amount', v_discount,
    'points_used', v_effective_pt,
    'remaining_points', v_member.points - v_effective_pt
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.redeem_loyalty_points(
  p_order_id UUID,
  p_member_id UUID,
  p_points INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_order      public.orders%ROWTYPE;
  v_member     public.loyalty_members%ROWTYPE;
  v_settings   JSONB;
  v_redeem_rate NUMERIC;
  v_discount   NUMERIC;
  v_existing_id UUID;
BEGIN
  IF auth.uid() IS NULL
     OR COALESCE(public.auth_role()::TEXT, '') NOT IN
          ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Hanya pengguna POS yang dapat menukar poin'
      USING ERRCODE = '42501';
  END IF;
  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'Jumlah poin yang ditukar harus > 0';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;
  IF v_order.status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah tidak dapat ditukar poinnya' USING ERRCODE = '22023';
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_order.outlet_id IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Order bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;

  -- Idempotensi dicek setelah otorisasi agar UUID order tidak menjadi oracle.
  SELECT id INTO v_existing_id
  FROM public.loyalty_transactions
  WHERE order_id = p_order_id AND type = 'redeem'
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_member
  FROM public.loyalty_members
  WHERE id = p_member_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_member.is_active
     OR v_member.outlet_id IS DISTINCT FROM v_order.outlet_id THEN
    RAISE EXCEPTION 'Member tidak valid untuk outlet ini' USING ERRCODE = '42501';
  END IF;
  IF v_order.loyalty_member_id IS NOT NULL
     AND v_order.loyalty_member_id IS DISTINCT FROM p_member_id THEN
    RAISE EXCEPTION 'Order sudah terhubung ke member lain' USING ERRCODE = '42501';
  END IF;
  IF v_member.points < p_points THEN
    RAISE EXCEPTION 'Saldo poin tidak cukup';
  END IF;

  SELECT loyalty_settings INTO v_settings
  FROM public.outlets WHERE id = v_order.outlet_id;
  v_redeem_rate := COALESCE((v_settings->>'redeem_rate')::NUMERIC, 1);
  IF v_redeem_rate <= 0 THEN
    RAISE EXCEPTION 'Konfigurasi redeem_rate outlet tidak valid';
  END IF;
  v_discount := FLOOR(p_points / v_redeem_rate);

  INSERT INTO public.loyalty_transactions(
    member_id, outlet_id, order_id, type, points, description
  ) VALUES (
    p_member_id, v_order.outlet_id, p_order_id, 'redeem', -p_points,
    'Redeem ' || p_points || ' poin → diskon Rp ' || v_discount::TEXT
      || ' untuk order #' || v_order.order_number
  );
  UPDATE public.loyalty_members
  SET points = points - p_points
  WHERE id = p_member_id;

  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders
  SET loyalty_discount = v_discount,
      redeemed_points = p_points,
      loyalty_member_id = COALESCE(loyalty_member_id, p_member_id)
  WHERE id = p_order_id;
  RETURN v_discount;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC)
  TO authenticated;

REVOKE ALL ON FUNCTION public.redeem_loyalty_points(UUID, UUID, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redeem_loyalty_points(UUID, UUID, INTEGER)
  TO authenticated;

COMMENT ON FUNCTION public.validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC) IS
  'Validasi redeem hanya untuk role POS terautentikasi pada outletnya.';
COMMENT ON FUNCTION public.redeem_loyalty_points(UUID, UUID, INTEGER) IS
  'Redeem atomik, idempoten, outlet-scoped, dan hanya untuk role POS terautentikasi.';

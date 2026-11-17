-- 141_transaction_integrity_hardening.sql
-- Hardening lanjutan setelah audit transaksi:
--   1. DML langsung ke payments/orders/items tidak boleh melewati RPC.
--   2. Status paid/void/cancelled hanya boleh berubah dari fungsi berotorisasi.
--   3. Total order harus konsisten dengan detail item saat dibayar.
--   4. Promo tidak boleh diklaim anonymous atau lintas outlet.
--   5. POS membuat header + item + extra dalam satu transaksi database.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS promo_id UUID,
  ADD COLUMN IF NOT EXISTS voucher_id UUID;

COMMENT ON COLUMN public.orders.promo_id IS
  'Snapshot referensi promo POS; pemakaian diklaim server saat order dibayar.';
COMMENT ON COLUMN public.orders.voucher_id IS
  'Snapshot referensi voucher POS; pemakaian diklaim server saat order dibayar.';

-- ── 1. Promo: hanya fungsi internal/RPC tepercaya yang boleh mengklaim ──────
CREATE OR REPLACE FUNCTION public.apply_promo_usage(
  p_promo_id UUID,
  p_voucher_id UUID DEFAULT NULL,
  p_order_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_outlet UUID;
  v_order_status public.order_status;
  v_promo promos%ROWTYPE;
  v_voucher vouchers%ROWTYPE;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id wajib diisi' USING ERRCODE = '22023';
  END IF;

  SELECT outlet_id, status
    INTO v_order_outlet, v_order_status
  FROM public.orders
  WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_order_status IN ('cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;

  IF p_promo_id IS NOT NULL THEN
    SELECT * INTO v_promo
    FROM public.promos
    WHERE id = p_promo_id
    FOR UPDATE;
    IF NOT FOUND OR v_promo.outlet_id IS DISTINCT FROM v_order_outlet THEN
      RAISE EXCEPTION 'Promo tidak valid untuk outlet order ini'
        USING ERRCODE = '42501';
    END IF;
    IF NOT v_promo.is_active THEN
      RAISE EXCEPTION 'Promo tidak aktif' USING ERRCODE = '22023';
    END IF;
    IF v_promo.start_date IS NOT NULL AND v_promo.start_date > jkt_today() THEN
      RAISE EXCEPTION 'Promo belum berlaku' USING ERRCODE = '22023';
    END IF;
    IF v_promo.end_date IS NOT NULL AND v_promo.end_date < jkt_today() THEN
      RAISE EXCEPTION 'Promo sudah kedaluwarsa' USING ERRCODE = '22023';
    END IF;
    IF v_promo.usage_limit IS NOT NULL
       AND v_promo.usage_count >= v_promo.usage_limit THEN
      RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan'
        USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.promo_usages
      WHERE promo_id = p_promo_id AND order_id = p_order_id
    ) THEN
      INSERT INTO public.promo_usages (order_id, promo_id)
      VALUES (p_order_id, p_promo_id);
      UPDATE public.promos
      SET usage_count = usage_count + 1, updated_at = now()
      WHERE id = p_promo_id;
    END IF;
  END IF;

  IF p_voucher_id IS NOT NULL THEN
    SELECT * INTO v_voucher
    FROM public.vouchers
    WHERE id = p_voucher_id
    FOR UPDATE;
    IF NOT FOUND OR p_promo_id IS NULL
       OR v_voucher.outlet_id IS DISTINCT FROM v_order_outlet
       OR (p_promo_id IS NOT NULL AND v_voucher.promo_id IS DISTINCT FROM p_promo_id) THEN
      RAISE EXCEPTION 'Voucher tidak valid untuk outlet/promo order ini'
        USING ERRCODE = '42501';
    END IF;
    IF NOT v_voucher.is_active THEN
      RAISE EXCEPTION 'Voucher tidak aktif' USING ERRCODE = '22023';
    END IF;
    IF v_voucher.usage_limit IS NOT NULL
       AND v_voucher.usage_count >= v_voucher.usage_limit THEN
      RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan'
        USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.promo_usages
      WHERE voucher_id = p_voucher_id AND order_id = p_order_id
    ) THEN
      INSERT INTO public.promo_usages (order_id, voucher_id)
      VALUES (p_order_id, p_voucher_id);
      UPDATE public.vouchers
      SET usage_count = usage_count + 1
      WHERE id = p_voucher_id;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_promo_usage(UUID, UUID, UUID)
  FROM PUBLIC, anon, authenticated;

-- ── 2. Validasi detail dan total sebelum payment ────────────────────────────
CREATE OR REPLACE FUNCTION public.validate_order_financial_integrity(
  p_order_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_item RECORD;
  v_item_sum NUMERIC := 0;
  v_min_unit NUMERIC;
  v_expected NUMERIC;
  v_option_invalid BOOLEAN;
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'Order tidak memiliki item' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN
    SELECT oi.*, mi.outlet_id AS menu_outlet_id, mi.price AS catalog_price
    FROM public.order_items oi
    JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
  LOOP
    IF v_item.menu_outlet_id IS DISTINCT FROM v_order.outlet_id THEN
      RAISE EXCEPTION 'Menu item berasal dari outlet lain' USING ERRCODE = '42501';
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM public.order_item_options oio
      WHERE oio.order_item_id = v_item.id
        AND NOT EXISTS (
          SELECT 1
          FROM public.menu_extra_options meo
          JOIN public.menu_item_extras mie ON mie.extra_id = meo.extra_id
          WHERE meo.id = oio.menu_extra_option_id
            AND mie.menu_item_id = v_item.menu_item_id
        )
    ) INTO v_option_invalid;
    IF v_option_invalid THEN
      RAISE EXCEPTION 'Extra order tidak valid untuk menu item'
        USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(SUM(meo.price), 0)
      INTO v_min_unit
    FROM public.order_item_options oio
    JOIN public.menu_extra_options meo ON meo.id = oio.menu_extra_option_id
    WHERE oio.order_item_id = v_item.id;
    v_min_unit := v_item.catalog_price + v_min_unit;

    IF v_item.unit_price < v_min_unit THEN
      RAISE EXCEPTION 'Harga item lebih rendah dari harga katalog/extra'
        USING ERRCODE = '22023';
    END IF;

    v_expected := v_item.unit_price * v_item.quantity;
    IF abs(v_item.subtotal - v_expected) > 0.01 THEN
      RAISE EXCEPTION 'Subtotal item tidak konsisten' USING ERRCODE = '22023';
    END IF;
    v_item_sum := v_item_sum + v_item.subtotal;
  END LOOP;

  IF abs(v_order.subtotal - v_item_sum) > 0.01 THEN
    RAISE EXCEPTION 'Subtotal order tidak sama dengan detail item'
      USING ERRCODE = '22023';
  END IF;
  IF v_order.discount_amount < 0 OR v_order.loyalty_discount < 0
     OR v_order.discount_amount + v_order.loyalty_discount > v_order.subtotal THEN
    RAISE EXCEPTION 'Diskon order tidak valid' USING ERRCODE = '22023';
  END IF;
  IF v_order.tax_amount < 0 OR v_order.service_charge < 0 THEN
    RAISE EXCEPTION 'Pajak/service charge tidak valid' USING ERRCODE = '22023';
  END IF;
  IF v_order.rounding NOT IN (0, 100, 500, 1000) THEN
    RAISE EXCEPTION 'Pembulatan order tidak valid' USING ERRCODE = '22023';
  END IF;

  v_expected := GREATEST(
    0,
    v_order.subtotal - v_order.discount_amount - v_order.loyalty_discount
  ) + CASE WHEN COALESCE(v_order.tax_inclusive, false)
           THEN 0 ELSE v_order.tax_amount END
    + v_order.service_charge;
  IF v_order.rounding > 0 THEN
    v_expected := round(v_expected / v_order.rounding) * v_order.rounding;
  END IF;
  IF abs(v_order.total_amount - v_expected) > 0.01 THEN
    RAISE EXCEPTION 'Total order tidak konsisten' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_order_financial_integrity(UUID)
  FROM PUBLIC, anon, authenticated;

-- redeem_loyalty_points adalah RPC lama yang masih dipakai self-order. Ia
-- mengubah diskon di header order dari dalam SECURITY DEFINER, jadi beri tanda
-- internal agar trigger nominal tidak menganggapnya sebagai REST update.
CREATE OR REPLACE FUNCTION public.redeem_loyalty_points(
  p_order_id UUID,
  p_member_id UUID,
  p_points INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_member public.loyalty_members%ROWTYPE;
  v_settings JSONB;
  v_redeem_rate NUMERIC;
  v_discount NUMERIC;
  v_existing_id UUID;
BEGIN
  SELECT id INTO v_existing_id
  FROM public.loyalty_transactions
  WHERE order_id = p_order_id AND type = 'redeem'
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN RETURN 0; END IF;
  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'Jumlah poin yang ditukar harus > 0';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  SELECT * INTO v_member FROM public.loyalty_members
  WHERE id = p_member_id FOR UPDATE;
  IF NOT FOUND OR v_member.outlet_id <> v_order.outlet_id THEN
    RAISE EXCEPTION 'Member tidak valid untuk outlet ini';
  END IF;
  IF v_member.points < p_points THEN
    RAISE EXCEPTION 'Saldo poin tidak cukup';
  END IF;

  SELECT loyalty_settings INTO v_settings
  FROM public.outlets WHERE id = v_order.outlet_id;
  v_redeem_rate := COALESCE((v_settings->>'redeem_rate')::NUMERIC, 1);
  v_discount := floor(p_points / v_redeem_rate);

  INSERT INTO public.loyalty_transactions(
    member_id, outlet_id, order_id, type, points, description
  ) VALUES (
    p_member_id, v_order.outlet_id, p_order_id, 'redeem', -p_points,
    'Redeem ' || p_points || ' poin → diskon Rp ' || v_discount::TEXT
      || ' untuk order #' || v_order.order_number
  );
  UPDATE public.loyalty_members
  SET points = points - p_points WHERE id = p_member_id;

  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders
  SET loyalty_discount = v_discount,
      redeemed_points = p_points,
      loyalty_member_id = COALESCE(loyalty_member_id, p_member_id)
  WHERE id = p_order_id;
  RETURN v_discount;
END;
$$;

REVOKE ALL ON FUNCTION public.redeem_loyalty_points(UUID, UUID, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_loyalty_points(UUID, UUID, INTEGER)
  TO authenticated;

-- Earn poin tidak boleh menjadi RPC anonim yang bisa dipanggil untuk order
-- aktif/batal atau member lain. Pemberian hanya setelah order paid dan member
-- harus sudah terhubung ke order tersebut.
CREATE OR REPLACE FUNCTION public.award_loyalty_points(
  p_order_id UUID,
  p_member_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_settings JSONB;
  v_rate NUMERIC;
  v_points INTEGER;
  v_existing_id UUID;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR v_order.status <> 'paid' THEN
    RAISE EXCEPTION 'Poin hanya dapat diberikan untuk order lunas'
      USING ERRCODE = '22023';
  END IF;
  IF NOT (COALESCE(public.is_owner(), false)
          OR v_order.outlet_id = public.auth_outlet_id())
     OR COALESCE(public.auth_role()::TEXT, '') NOT IN
          ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang memberikan poin order ini'
      USING ERRCODE = '42501';
  END IF;
  IF v_order.loyalty_member_id IS NOT NULL
     AND v_order.loyalty_member_id IS DISTINCT FROM p_member_id THEN
    RAISE EXCEPTION 'Member tidak sesuai dengan order' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.loyalty_members
    WHERE id = p_member_id AND outlet_id = v_order.outlet_id AND is_active
  ) THEN
    RAISE EXCEPTION 'Member tidak valid untuk outlet ini' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_existing_id
  FROM public.loyalty_transactions
  WHERE order_id = p_order_id AND type = 'earn'
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN RETURN 0; END IF;

  SELECT loyalty_settings INTO v_settings
  FROM public.outlets WHERE id = v_order.outlet_id;
  v_rate := COALESCE((v_settings->>'points_per_rupiah')::NUMERIC, 0);
  IF v_rate <= 0 THEN RETURN 0; END IF;
  v_points := floor(v_order.subtotal * v_rate)::INTEGER;
  IF v_points <= 0 THEN RETURN 0; END IF;

  INSERT INTO public.loyalty_transactions(
    member_id, outlet_id, order_id, type, points, description
  ) VALUES (
    p_member_id, v_order.outlet_id, p_order_id, 'earn', v_points,
    'Earn dari order #' || v_order.order_number
  );
  UPDATE public.loyalty_members
  SET points = points + v_points WHERE id = p_member_id;
  UPDATE public.orders
  SET loyalty_member_id = p_member_id
  WHERE id = p_order_id AND loyalty_member_id IS NULL;
  RETURN v_points;
END;
$$;

REVOKE ALL ON FUNCTION public.award_loyalty_points(UUID, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.award_loyalty_points(UUID, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.settle_pos_order_adjustments(p_order_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_promo public.promos%ROWTYPE;
  v_expected_discount NUMERIC := 0;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  IF v_order.promo_id IS NOT NULL OR v_order.voucher_id IS NOT NULL THEN
    IF v_order.promo_id IS NULL AND v_order.voucher_id IS NOT NULL THEN
      RAISE EXCEPTION 'Voucher wajib terhubung ke promo' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_promo FROM public.promos
    WHERE id = v_order.promo_id AND outlet_id = v_order.outlet_id;
    IF NOT FOUND OR NOT v_promo.is_active THEN
      RAISE EXCEPTION 'Promo order tidak valid' USING ERRCODE = '22023';
    END IF;
    IF v_promo.start_date IS NOT NULL AND v_promo.start_date > jkt_today() THEN
      RAISE EXCEPTION 'Promo belum berlaku' USING ERRCODE = '22023';
    END IF;
    IF v_promo.end_date IS NOT NULL AND v_promo.end_date < jkt_today() THEN
      RAISE EXCEPTION 'Promo sudah kedaluwarsa' USING ERRCODE = '22023';
    END IF;
    IF v_order.subtotal < v_promo.min_order THEN
      RAISE EXCEPTION 'Minimum order promo belum terpenuhi' USING ERRCODE = '22023';
    END IF;
    v_expected_discount := CASE v_promo.type
      WHEN 'percentage' THEN LEAST(
        round(v_order.subtotal * v_promo.value / 100, 0),
        COALESCE(v_promo.max_discount, round(v_order.subtotal * v_promo.value / 100, 0))
      )
      WHEN 'fixed' THEN LEAST(v_promo.value, v_order.subtotal)
      ELSE 0
    END;
    IF abs(COALESCE(v_order.discount_amount, 0) - v_expected_discount) > 0.01 THEN
      RAISE EXCEPTION 'Nominal diskon promo tidak sesuai aturan server'
        USING ERRCODE = '22023';
    END IF;
    PERFORM public.apply_promo_usage(
      v_order.promo_id, v_order.voucher_id, v_order.id
    );
  END IF;

  IF COALESCE(v_order.redeemed_points, 0) > 0 THEN
    IF v_order.loyalty_member_id IS NULL THEN
      RAISE EXCEPTION 'Member loyalty untuk redeem tidak ditemukan'
        USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('app.order_financial_mutation', 'on', true);
    PERFORM public.redeem_loyalty_points(
      v_order.id, v_order.loyalty_member_id, v_order.redeemed_points
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.settle_pos_order_adjustments(UUID)
  FROM PUBLIC, anon, authenticated;

-- ── 3. Pagar hanya lewat RPC dan total harus sudah tervalidasi ──────────────
CREATE OR REPLACE FUNCTION public.record_pos_payment(
  p_order_id UUID,
  p_outlet_id UUID,
  p_method public.payment_method,
  p_amount NUMERIC,
  p_reference_number TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_finalize BOOLEAN DEFAULT TRUE,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_payment_id UUID;
  v_paid NUMERIC;
  v_is_duplicate BOOLEAN := false;
  v_will_be_paid BOOLEAN := false;
BEGIN
  IF p_order_id IS NULL OR p_outlet_id IS NULL OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Order, outlet, dan nominal pembayaran wajib valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.outlet_id <> p_outlet_id THEN
    RAISE EXCEPTION 'Order tidak ditemukan di outlet tersebut'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin', 'manajer', 'kasir')
     OR NOT (COALESCE(public.is_owner(), false)
             OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berwenang membayar order ini' USING ERRCODE = '42501';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_payment_id
    FROM public.payments
    WHERE order_id = p_order_id AND idempotency_key = p_idempotency_key;
    v_is_duplicate := v_payment_id IS NOT NULL;
  END IF;

  IF v_order.status IN ('cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;
  IF v_order.status = 'paid' AND NOT v_is_duplicate THEN
    RAISE EXCEPTION 'Order sudah lunas' USING ERRCODE = '22023';
  END IF;

  -- Retry terhadap payment yang sama cukup mengembalikan keadaan terakhir.
  IF v_is_duplicate AND v_order.status = 'paid' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments WHERE order_id = p_order_id;
    RETURN jsonb_build_object(
      'payment_id', v_payment_id, 'paid_total', v_paid,
      'order_total', v_order.total_amount, 'status', 'paid', 'duplicate', true
    );
  END IF;

  PERFORM public.validate_order_financial_integrity(p_order_id);
  IF p_finalize THEN
    PERFORM public.settle_pos_order_adjustments(p_order_id);
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    PERFORM public.validate_order_financial_integrity(p_order_id);
  END IF;

  IF NOT v_is_duplicate THEN
    INSERT INTO public.payments (
      order_id, outlet_id, method, amount, reference_number, paid_at,
      idempotency_key
    ) VALUES (
      p_order_id, p_outlet_id, p_method, p_amount, p_reference_number,
      COALESCE(p_paid_at, now()), p_idempotency_key
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_payment_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments WHERE order_id = p_order_id;
  v_will_be_paid := p_finalize AND v_paid >= v_order.total_amount;

  IF v_will_be_paid THEN
    PERFORM set_config('app.order_status_mutation', 'on', true);
    UPDATE public.orders
    SET status = 'paid', updated_at = now()
    WHERE id = p_order_id
      AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id, 'paid_total', v_paid,
    'order_total', v_order.total_amount,
    'status', CASE WHEN v_will_be_paid THEN 'paid' ELSE v_order.status::TEXT END,
    'duplicate', v_is_duplicate
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) TO authenticated;

-- ── 4. Status hanya melalui RPC terkontrol ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.advance_order_status(
  p_order_id UUID,
  p_status public.order_status
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang mengubah status' USING ERRCODE = '42501';
  END IF;
  IF p_status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Status ini hanya boleh diubah oleh alur pembayaran/refund'
      USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(public.is_owner(), false)
                       OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Order tidak ditemukan atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;
  IF v_order.status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Order terminal tidak boleh dibuka kembali'
      USING ERRCODE = '42501';
  END IF;
  IF p_status = 'draft'
     OR array_position(
          ARRAY['draft', 'confirmed', 'preparing', 'ready', 'served']::TEXT[],
          p_status::TEXT
        ) < array_position(
          ARRAY['draft', 'confirmed', 'preparing', 'ready', 'served']::TEXT[],
          v_order.status::TEXT
        ) THEN
    RAISE EXCEPTION 'Status order tidak boleh mundur' USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders SET status = p_status, updated_at = now()
  WHERE id = p_order_id;
  RETURN jsonb_build_object('id', p_order_id, 'status', p_status::TEXT);
END;
$$;

REVOKE ALL ON FUNCTION public.advance_order_status(UUID, public.order_status)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.advance_order_status(UUID, public.order_status)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_order_direct_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- Perubahan internal dari trigger snapshot/tax tidak boleh diblokir.
  IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     AND current_setting('app.order_status_mutation', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Perubahan status order wajib melalui RPC resmi'
      USING ERRCODE = '42501';
  END IF;

  IF (
      NEW.outlet_id IS DISTINCT FROM OLD.outlet_id OR
      NEW.order_number IS DISTINCT FROM OLD.order_number OR
      NEW.order_type IS DISTINCT FROM OLD.order_type OR
      NEW.created_by IS DISTINCT FROM OLD.created_by OR
      NEW.shift_id IS DISTINCT FROM OLD.shift_id OR
      NEW.table_id IS DISTINCT FROM OLD.table_id OR
      NEW.created_at IS DISTINCT FROM OLD.created_at OR
      NEW.local_receipt_no IS DISTINCT FROM OLD.local_receipt_no OR
      NEW.promo_id IS DISTINCT FROM OLD.promo_id OR
      NEW.voucher_id IS DISTINCT FROM OLD.voucher_id
     )
     AND current_setting('app.order_metadata_mutation', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Metadata order wajib diubah melalui RPC resmi'
      USING ERRCODE = '42501';
  END IF;

  IF (
      NEW.subtotal IS DISTINCT FROM OLD.subtotal OR
      NEW.discount_amount IS DISTINCT FROM OLD.discount_amount OR
      NEW.loyalty_discount IS DISTINCT FROM OLD.loyalty_discount OR
      NEW.tax_amount IS DISTINCT FROM OLD.tax_amount OR
      NEW.service_charge IS DISTINCT FROM OLD.service_charge OR
      NEW.total_amount IS DISTINCT FROM OLD.total_amount OR
      NEW.tax_inclusive IS DISTINCT FROM OLD.tax_inclusive OR
      NEW.rounding IS DISTINCT FROM OLD.rounding
     )
     AND current_setting('app.order_financial_mutation', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Perubahan nominal order wajib melalui RPC resmi'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

-- ── 5a. Metadata order juga melalui RPC, bukan update REST ────────────────
CREATE OR REPLACE FUNCTION public.assign_order_payment_context(
  p_order_id UUID,
  p_shift_id UUID,
  p_force_shift BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang mengatribusikan pembayaran'
      USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(public.is_owner(), false)
                       OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Order tidak ditemukan atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;
  IF p_shift_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.shifts s
    WHERE s.id = p_shift_id AND s.outlet_id = v_order.outlet_id
  ) THEN
    RAISE EXCEPTION 'Till tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.order_metadata_mutation', 'on', true);
  UPDATE public.orders
  SET created_by = COALESCE(created_by, auth.uid()),
      shift_id = CASE
        WHEN p_force_shift OR created_by IS NULL THEN p_shift_id
        ELSE shift_id
      END,
      updated_at = now()
  WHERE id = p_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.transfer_order_table(
  p_order_id UUID,
  p_table_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang memindahkan meja'
      USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(public.is_owner(), false)
                       OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Order tidak ditemukan atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;
  IF v_order.status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah ditutup' USING ERRCODE = '22023';
  END IF;
  IF p_table_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.restaurant_tables t
    WHERE t.id = p_table_id AND t.outlet_id = v_order.outlet_id AND t.is_active
  ) THEN
    RAISE EXCEPTION 'Meja tidak tersedia di outlet order'
      USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.order_metadata_mutation', 'on', true);
  UPDATE public.orders
  SET table_id = p_table_id, updated_at = now()
  WHERE id = p_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_order_payment_context(UUID, UUID, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_order_payment_context(UUID, UUID, BOOLEAN)
  TO authenticated;
REVOKE ALL ON FUNCTION public.transfer_order_table(UUID, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_order_table(UUID, UUID)
  TO authenticated;

DROP TRIGGER IF EXISTS trg_guard_order_direct_mutation ON public.orders;
CREATE TRIGGER trg_guard_order_direct_mutation
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_order_direct_mutation();

-- ── 5. Owner Panel memakai RPC khusus untuk void ────────────────────────────
CREATE OR REPLACE FUNCTION public.owner_panel_void_order(
  p_order_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat melakukan void'
      USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(public.is_owner(), false)
                       OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Order tidak ditemukan atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;
  IF v_order.status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan void' USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders
  SET status = 'void', void_reason = p_reason, approved_by = auth.uid(), updated_at = now()
  WHERE id = p_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.owner_panel_void_order(UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_panel_void_order(UUID, TEXT)
  TO authenticated;

-- ── 6. Direct DML tidak boleh menjadi jalan transaksi ──────────────────────
REVOKE INSERT, UPDATE, DELETE ON public.payments FROM anon, authenticated;
REVOKE INSERT ON public.orders FROM anon, authenticated;
REVOKE UPDATE ON public.orders FROM anon, authenticated;
REVOKE INSERT ON public.order_items FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.order_item_options FROM anon, authenticated;

DROP POLICY IF EXISTS "orders_delete" ON public.orders;
CREATE POLICY "orders_delete" ON public.orders
  FOR DELETE TO authenticated
  USING (
    status = 'draft'
    AND (
      public.is_owner()
      OR (
        public.auth_role() IN ('admin', 'manajer', 'kasir')
        AND outlet_id = public.auth_outlet_id()
      )
    )
  );

DROP POLICY IF EXISTS "order_items_insert" ON public.order_items;
CREATE POLICY "order_items_insert" ON public.order_items
  FOR INSERT TO authenticated
  WITH CHECK (false);
DROP POLICY IF EXISTS "order_items_insert_anon" ON public.order_items;
CREATE POLICY "order_items_insert_anon" ON public.order_items
  FOR INSERT TO anon
  WITH CHECK (false);

DROP POLICY IF EXISTS "order_items_update" ON public.order_items;
CREATE POLICY "order_items_update" ON public.order_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id AND o.status = 'draft'
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id AND o.status = 'draft'
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

DROP POLICY IF EXISTS "order_items_delete" ON public.order_items;
CREATE POLICY "order_items_delete" ON public.order_items
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id AND o.status = 'draft'
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

-- Jalur self-order customer sekarang selalu memakai create_self_order SECURITY
-- DEFINER, sehingga policy INSERT anonymous lama tidak lagi diperlukan.
DROP POLICY IF EXISTS "orders_insert_anon" ON public.orders;
DROP POLICY IF EXISTS "order_items_insert_anon" ON public.order_items;
DROP POLICY IF EXISTS "oio_insert_anon" ON public.order_item_options;

-- merge_orders adalah RPC lama yang sah, tetapi ia mengubah nominal target dan
-- status sumber. Pasang flag internal agar trigger hardening tidak menganggap
-- jalur ini sebagai update REST.
CREATE OR REPLACE FUNCTION public.merge_orders(p_source UUID, p_target UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_src public.orders%ROWTYPE;
  v_tgt public.orders%ROWTYPE;
  v_active TEXT[] := ARRAY['draft', 'confirmed', 'preparing', 'ready', 'served'];
BEGIN
  IF p_source = p_target THEN
    RAISE EXCEPTION 'Order sumber dan tujuan tidak boleh sama';
  END IF;

  SELECT * INTO v_src FROM public.orders WHERE id = p_source FOR UPDATE;
  SELECT * INTO v_tgt FROM public.orders WHERE id = p_target FOR UPDATE;
  IF v_src.id IS NULL OR v_tgt.id IS NULL THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;
  IF NOT (public.is_owner()
          OR (v_src.outlet_id = public.auth_outlet_id()
              AND v_tgt.outlet_id = public.auth_outlet_id())) THEN
    RAISE EXCEPTION 'Tidak berizin menggabung order ini';
  END IF;
  IF v_src.outlet_id <> v_tgt.outlet_id THEN
    RAISE EXCEPTION 'Order beda outlet tidak bisa digabung';
  END IF;
  IF NOT (v_src.status::TEXT = ANY(v_active))
     OR NOT (v_tgt.status::TEXT = ANY(v_active)) THEN
    RAISE EXCEPTION 'Hanya order aktif (belum lunas) yang bisa digabung';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = p_source) THEN
    RAISE EXCEPTION 'Order sumber sudah punya pembayaran — tidak bisa digabung';
  END IF;

  UPDATE public.order_items SET order_id = p_target WHERE order_id = p_source;
  UPDATE public.stock_transactions SET order_id = p_target WHERE order_id = p_source;

  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders SET
    subtotal = v_tgt.subtotal + v_src.subtotal,
    discount_amount = v_tgt.discount_amount + v_src.discount_amount,
    tax_amount = v_tgt.tax_amount + v_src.tax_amount,
    service_charge = v_tgt.service_charge + v_src.service_charge,
    total_amount = v_tgt.total_amount + v_src.total_amount,
    updated_at = now()
  WHERE id = p_target;

  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders SET
    status = 'void',
    void_reason = 'Digabung ke order ' || v_tgt.order_number,
    updated_at = now()
  WHERE id = p_source;

  RETURN jsonb_build_object('merged_into', p_target, 'source_voided', p_source);
END;
$$;

REVOKE ALL ON FUNCTION public.merge_orders(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merge_orders(UUID, UUID) TO authenticated;

-- Kalkulasi pajak/service untuk POS dilakukan di database. Parameter nominal
-- dari client tetap diterima demi kompatibilitas payload lama, tetapi tidak
-- dipercaya saat header atau open bill dihitung ulang.
CREATE OR REPLACE FUNCTION public.calculate_server_order_totals(
  p_outlet_id UUID,
  p_order_type public.order_type,
  p_subtotal NUMERIC,
  p_discount NUMERIC,
  p_loyalty_discount NUMERIC
)
RETURNS TABLE(
  tax_amount NUMERIC,
  tax_inclusive BOOLEAN,
  service_charge NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_rules JSONB;
  v_rule JSONB;
  v_pct NUMERIC;
  v_base NUMERIC;
  v_tax NUMERIC := 0;
  v_svc_pct NUMERIC := 0;
  v_has_inclusive BOOLEAN := false;
  v_has_exclusive BOOLEAN := false;
  v_active BOOLEAN;
  v_inclusive BOOLEAN;
  v_calculation TEXT;
  v_order_types JSONB;
BEGIN
  SELECT COALESCE(settings, '{}'::JSONB) INTO v_settings
  FROM public.outlets WHERE id = p_outlet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Outlet tidak ditemukan'; END IF;

  v_rules := v_settings->'taxes';
  IF jsonb_typeof(v_rules) = 'array' AND jsonb_array_length(v_rules) > 0 THEN
    FOR v_rule IN SELECT value FROM jsonb_array_elements(v_rules) LOOP
      v_active := COALESCE((v_rule->>'active')::BOOLEAN, true);
      v_order_types := v_rule->'order_types';
      IF jsonb_typeof(v_order_types) = 'array'
         AND jsonb_array_length(v_order_types) > 0
         AND NOT (v_order_types ? p_order_type::TEXT) THEN
        v_active := false;
      END IF;
      v_pct := GREATEST(COALESCE((v_rule->>'percent')::NUMERIC, 0), 0);
      v_inclusive := COALESCE((v_rule->>'inclusive')::BOOLEAN, false);
      v_calculation := COALESCE(v_rule->>'calculation', 'before_discount');
      v_base := CASE WHEN v_calculation = 'after_discount'
        THEN GREATEST(COALESCE(p_subtotal, 0)
                      - COALESCE(p_discount, 0)
                      - COALESCE(p_loyalty_discount, 0), 0)
        ELSE GREATEST(COALESCE(p_subtotal, 0), 0)
      END;
      IF v_active AND v_pct > 0 THEN
        v_tax := v_tax + CASE WHEN v_inclusive
          THEN round(v_base - v_base / (1 + v_pct / 100))
          ELSE round(v_base * v_pct / 100)
        END;
        IF v_inclusive THEN v_has_inclusive := true;
        ELSE v_has_exclusive := true;
        END IF;
      END IF;
    END LOOP;
  ELSE
    v_active := COALESCE((v_settings->>'tax_active')::BOOLEAN, true);
    v_pct := GREATEST(COALESCE((v_settings->>'tax_percent')::NUMERIC, 0), 0);
    v_inclusive := COALESCE((v_settings->>'tax_inclusive')::BOOLEAN, false);
    v_calculation := COALESCE(v_settings->>'tax_calculation', 'before_discount');
    v_base := CASE WHEN v_calculation = 'after_discount'
      THEN GREATEST(COALESCE(p_subtotal, 0)
                    - COALESCE(p_discount, 0)
                    - COALESCE(p_loyalty_discount, 0), 0)
      ELSE GREATEST(COALESCE(p_subtotal, 0), 0)
    END;
    IF v_active AND v_pct > 0 THEN
      v_tax := CASE WHEN v_inclusive
        THEN round(v_base - v_base / (1 + v_pct / 100))
        ELSE round(v_base * v_pct / 100)
      END;
      v_has_inclusive := v_inclusive;
      v_has_exclusive := NOT v_inclusive;
    END IF;
  END IF;

  v_svc_pct := GREATEST(
    COALESCE((v_settings->>'service_charge_percent')::NUMERIC, 0), 0
  );
  tax_amount := v_tax;
  tax_inclusive := v_has_inclusive AND NOT v_has_exclusive;
  service_charge := round(GREATEST(COALESCE(p_subtotal, 0), 0) * v_svc_pct / 100);
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.calculate_server_order_totals(
  UUID, public.order_type, NUMERIC, NUMERIC, NUMERIC
) FROM PUBLIC, anon, authenticated;

-- ── 7. CRUD atomik POS ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_pos_order(
  p_outlet_id UUID,
  p_order_type public.order_type,
  p_status public.order_status,
  p_items JSONB,
  p_created_by UUID,
  p_discount_amount NUMERIC DEFAULT 0,
  p_tax_amount NUMERIC DEFAULT 0,
  p_service_charge NUMERIC DEFAULT 0,
  p_tax_inclusive BOOLEAN DEFAULT FALSE,
  p_rounding INTEGER DEFAULT 0,
  p_table_id UUID DEFAULT NULL,
  p_shift_id UUID DEFAULT NULL,
  p_customer_name TEXT DEFAULT NULL,
  p_loyalty_member_id UUID DEFAULT NULL,
  p_loyalty_discount NUMERIC DEFAULT 0,
  p_redeemed_points INTEGER DEFAULT 0,
  p_promo_id UUID DEFAULT NULL,
  p_voucher_id UUID DEFAULT NULL,
  p_order_id UUID DEFAULT NULL,
  p_created_at TIMESTAMPTZ DEFAULT NULL,
  p_local_receipt_no TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID := COALESCE(p_order_id, gen_random_uuid());
  v_order_number TEXT;
  v_existing public.orders%ROWTYPE;
  v_item JSONB;
  v_options JSONB;
  v_mid UUID;
  v_qty INTEGER;
  v_unit NUMERIC;
  v_base NUMERIC;
  v_extra_total NUMERIC;
  v_option_count INTEGER;
  v_valid_option_count INTEGER;
  v_subtotal NUMERIC := 0;
  v_item_id UUID;
  v_server_tax NUMERIC;
  v_server_inclusive BOOLEAN;
  v_server_service NUMERIC;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin', 'manajer', 'kasir')
     OR NOT (COALESCE(public.is_owner(), false)
             OR p_outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berwenang membuat order di outlet ini' USING ERRCODE = '42501';
  END IF;
  IF p_created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'created_by harus merupakan pengguna yang sedang login'
      USING ERRCODE = '42501';
  END IF;
  IF p_table_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.restaurant_tables t
    WHERE t.id = p_table_id AND t.outlet_id = p_outlet_id AND t.is_active
  ) THEN
    RAISE EXCEPTION 'Meja tidak tersedia di outlet order'
      USING ERRCODE = '22023';
  END IF;
  IF p_shift_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.shifts s
    WHERE s.id = p_shift_id AND s.outlet_id = p_outlet_id
  ) THEN
    RAISE EXCEPTION 'Till tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF p_loyalty_member_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.loyalty_members lm
    WHERE lm.id = p_loyalty_member_id AND lm.outlet_id = p_outlet_id
  ) THEN
    RAISE EXCEPTION 'Member loyalty tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('draft', 'confirmed') THEN
    RAISE EXCEPTION 'Status awal order tidak valid' USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Keranjang order kosong' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing FROM public.orders WHERE id = v_order_id;
  IF FOUND THEN
    IF v_existing.outlet_id IS DISTINCT FROM p_outlet_id THEN
      RAISE EXCEPTION 'Order id sudah dipakai outlet lain' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object(
      'order_id', v_existing.id, 'order_number', v_existing.order_number,
      'total_amount', v_existing.total_amount, 'already_exists', true
    );
  END IF;

  IF p_discount_amount < 0 OR p_loyalty_discount < 0
     OR p_tax_amount < 0 OR p_service_charge < 0
     OR COALESCE(p_redeemed_points, 0) < 0 THEN
    RAISE EXCEPTION 'Komponen nominal order tidak valid' USING ERRCODE = '22023';
  END IF;
  IF p_discount_amount > 0 AND p_promo_id IS NULL THEN
    RAISE EXCEPTION 'Diskon order wajib berasal dari promo tervalidasi'
      USING ERRCODE = '22023';
  END IF;
  IF p_voucher_id IS NOT NULL AND p_promo_id IS NULL THEN
    RAISE EXCEPTION 'Voucher wajib terhubung ke promo'
      USING ERRCODE = '22023';
  END IF;
  IF p_loyalty_discount > 0
     AND (p_loyalty_member_id IS NULL OR COALESCE(p_redeemed_points, 0) <= 0) THEN
    RAISE EXCEPTION 'Diskon loyalty wajib memiliki redeem poin'
      USING ERRCODE = '22023';
  END IF;
  IF p_rounding NOT IN (0, 100, 500, 1000) THEN
    RAISE EXCEPTION 'Pembulatan order tidak valid' USING ERRCODE = '22023';
  END IF;

  v_order_number := public.get_next_pos_order_number(p_outlet_id);
  INSERT INTO public.orders (
    id, outlet_id, order_number, order_type, table_id, shift_id,
    customer_name, status, subtotal, discount_amount, loyalty_discount,
    redeemed_points, loyalty_member_id, tax_amount, service_charge,
    tax_inclusive, rounding, total_amount, stock_deducted, created_by,
    created_at, local_receipt_no, promo_id, voucher_id
  ) VALUES (
    v_order_id, p_outlet_id, v_order_number, p_order_type, p_table_id, p_shift_id,
    p_customer_name, p_status, 0, p_discount_amount, p_loyalty_discount,
    p_redeemed_points, p_loyalty_member_id, p_tax_amount, p_service_charge,
    p_tax_inclusive, p_rounding, 0, false, p_created_by,
    COALESCE(p_created_at, now()), p_local_receipt_no, p_promo_id, p_voucher_id
  );

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_mid := (v_item->>'menu_item_id')::UUID;
    v_qty := COALESCE((v_item->>'quantity')::INTEGER, 0);
    v_unit := (v_item->>'unit_price')::NUMERIC;
    IF v_qty <= 0 OR v_unit IS NULL THEN
      RAISE EXCEPTION 'Item order tidak valid' USING ERRCODE = '22023';
    END IF;

    SELECT price INTO v_base
    FROM public.menu_items
    WHERE id = v_mid AND outlet_id = p_outlet_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Menu item tidak tersedia di outlet ini' USING ERRCODE = '22023';
    END IF;

    v_options := CASE
      WHEN jsonb_typeof(v_item->'extras') = 'array' THEN v_item->'extras'
      WHEN jsonb_typeof(v_item->'options') = 'array' THEN v_item->'options'
      ELSE '[]'::JSONB
    END;
    SELECT jsonb_array_length(v_options) INTO v_option_count;
    SELECT count(*) INTO v_valid_option_count
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID
    JOIN public.menu_item_extras mie
      ON mie.extra_id = meo.extra_id AND mie.menu_item_id = v_mid;
    IF v_option_count <> v_valid_option_count THEN
      RAISE EXCEPTION 'Extra order tidak valid' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(SUM(meo.price), 0) INTO v_extra_total
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID;
    IF v_unit < v_base + v_extra_total THEN
      RAISE EXCEPTION 'Harga item lebih rendah dari harga katalog/extra'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items (
      order_id, menu_item_id, quantity, unit_price, subtotal, notes
    ) VALUES (
      v_order_id, v_mid, v_qty, v_unit, v_qty * v_unit,
      NULLIF(v_item->>'notes', '')
    ) RETURNING id INTO v_item_id;

    INSERT INTO public.order_item_options (
      order_item_id, menu_extra_id, menu_extra_option_id,
      extra_name, option_name, price
    )
    SELECT v_item_id, meo.extra_id, meo.id, me.name, meo.name, meo.price
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID
    JOIN public.menu_extras me ON me.id = meo.extra_id;

    v_subtotal := v_subtotal + v_qty * v_unit;
  END LOOP;

  IF p_discount_amount + p_loyalty_discount > v_subtotal THEN
    RAISE EXCEPTION 'Diskon melebihi subtotal order' USING ERRCODE = '22023';
  END IF;
  SELECT tax_amount, tax_inclusive, service_charge
    INTO v_server_tax, v_server_inclusive, v_server_service
  FROM public.calculate_server_order_totals(
    p_outlet_id, p_order_type, v_subtotal,
    p_discount_amount, p_loyalty_discount
  );
  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders
  SET subtotal = v_subtotal,
      tax_amount = v_server_tax,
      tax_inclusive = v_server_inclusive,
      service_charge = v_server_service
  WHERE id = v_order_id;
  PERFORM public.validate_order_financial_integrity(v_order_id);

  SELECT total_amount INTO v_existing.total_amount
  FROM public.orders WHERE id = v_order_id;
  RETURN jsonb_build_object(
    'order_id', v_order_id, 'order_number', v_order_number,
    'total_amount', v_existing.total_amount, 'already_exists', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_pos_order(
  UUID, public.order_type, public.order_status, JSONB, UUID, NUMERIC, NUMERIC,
  NUMERIC, BOOLEAN, INTEGER, UUID, UUID, TEXT, UUID, NUMERIC, INTEGER, UUID,
  UUID, UUID, TIMESTAMPTZ, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_pos_order(
  UUID, public.order_type, public.order_status, JSONB, UUID, NUMERIC, NUMERIC,
  NUMERIC, BOOLEAN, INTEGER, UUID, UUID, TEXT, UUID, NUMERIC, INTEGER, UUID,
  UUID, UUID, TIMESTAMPTZ, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.create_pos_order IS
  'Membuat order POS + item + extra secara atomik dan idempoten.';

-- ── 8. Open bill: tambah item + hitung ulang dalam satu transaksi ────────────
CREATE OR REPLACE FUNCTION public.append_order_items(
  p_order_id UUID,
  p_items JSONB,
  p_tax_percent NUMERIC DEFAULT 0,
  p_tax_active BOOLEAN DEFAULT TRUE,
  p_service_charge_percent NUMERIC DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_item JSONB;
  v_options JSONB;
  v_mid UUID;
  v_qty INTEGER;
  v_unit NUMERIC;
  v_base NUMERIC;
  v_extra_total NUMERIC;
  v_option_count INTEGER;
  v_valid_option_count INTEGER;
  v_item_id UUID;
  v_ids UUID[] := ARRAY[]::UUID[];
  v_subtotal NUMERIC;
  v_tax NUMERIC;
  v_service NUMERIC;
  v_server_inclusive BOOLEAN;
  v_server_service NUMERIC;
  v_result JSONB := '[]'::JSONB;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang menambah item' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(public.is_owner(), false)
                       OR v_order.outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Order tidak ditemukan atau tidak berwenang' USING ERRCODE = '42501';
  END IF;
  IF v_order.status IN ('paid', 'cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah ditutup' USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Item tambahan kosong' USING ERRCODE = '22023';
  END IF;
  IF p_tax_percent < 0 OR p_service_charge_percent < 0 THEN
    RAISE EXCEPTION 'Pajak/service charge tidak valid' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_mid := (v_item->>'menu_item_id')::UUID;
    v_qty := COALESCE((v_item->>'quantity')::INTEGER, 0);
    v_unit := (v_item->>'unit_price')::NUMERIC;
    SELECT price INTO v_base FROM public.menu_items
    WHERE id = v_mid AND outlet_id = v_order.outlet_id;
    IF NOT FOUND OR v_qty <= 0 OR v_unit IS NULL THEN
      RAISE EXCEPTION 'Item tambahan tidak valid' USING ERRCODE = '22023';
    END IF;
    v_options := CASE
      WHEN jsonb_typeof(v_item->'extras') = 'array' THEN v_item->'extras'
      WHEN jsonb_typeof(v_item->'options') = 'array' THEN v_item->'options'
      ELSE '[]'::JSONB
    END;
    SELECT jsonb_array_length(v_options) INTO v_option_count;
    SELECT count(*) INTO v_valid_option_count
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID
    JOIN public.menu_item_extras mie ON mie.extra_id = meo.extra_id AND mie.menu_item_id = v_mid;
    IF v_option_count <> v_valid_option_count THEN
      RAISE EXCEPTION 'Extra item tambahan tidak valid' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(SUM(meo.price), 0) INTO v_extra_total
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID;
    IF v_unit < v_base + v_extra_total THEN
      RAISE EXCEPTION 'Harga item tambahan tidak valid' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.order_items(order_id, menu_item_id, quantity, unit_price, subtotal, notes)
    VALUES (p_order_id, v_mid, v_qty, v_unit, v_qty * v_unit, NULLIF(v_item->>'notes', ''))
    RETURNING id INTO v_item_id;
    v_ids := array_append(v_ids, v_item_id);
    INSERT INTO public.order_item_options(
      order_item_id, menu_extra_id, menu_extra_option_id, extra_name, option_name, price
    )
    SELECT v_item_id, meo.extra_id, meo.id, me.name, meo.name, meo.price
    FROM jsonb_array_elements(v_options) x
    JOIN public.menu_extra_options meo ON meo.id = (x->>'menu_extra_option_id')::UUID
    JOIN public.menu_extras me ON me.id = meo.extra_id;
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'id', v_item_id, 'menu_item_id', v_mid, 'quantity', v_qty,
      'unit_price', v_unit, 'subtotal', v_qty * v_unit,
      'notes', NULLIF(v_item->>'notes', '')
    ));
  END LOOP;

  SELECT COALESCE(SUM(subtotal), 0) INTO v_subtotal
  FROM public.order_items WHERE order_id = p_order_id;
  SELECT tax_amount, tax_inclusive, service_charge
    INTO v_tax, v_server_inclusive, v_server_service
  FROM public.calculate_server_order_totals(
    v_order.outlet_id, v_order.order_type, v_subtotal,
    v_order.discount_amount, v_order.loyalty_discount
  );
  v_service := v_server_service;
  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders
  SET subtotal = v_subtotal, tax_amount = v_tax,
      tax_inclusive = v_server_inclusive, service_charge = v_service,
      updated_at = now()
  WHERE id = p_order_id;
  PERFORM public.deduct_stock_for_items(p_order_id, v_ids);
  PERFORM public.validate_order_financial_integrity(p_order_id);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.append_order_items(UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.append_order_items(UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC)
  TO authenticated;

-- ── 9. Finalisasi split juga memakai penyesuaian server ──────────────────────
CREATE OR REPLACE FUNCTION public.finalize_split_payment(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_paid NUMERIC;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = 'P0002'; END IF;
  IF NOT (COALESCE(public.is_owner(), false)
          OR public.auth_outlet_id() IS NOT DISTINCT FROM v_order.outlet_id) THEN
    RAISE EXCEPTION 'Tidak berwenang atas order ini' USING ERRCODE = '42501';
  END IF;
  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('status', 'paid', 'already', true);
  END IF;
  IF v_order.status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;

  PERFORM public.validate_order_financial_integrity(p_order_id);
  PERFORM public.settle_pos_order_adjustments(p_order_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  PERFORM public.validate_order_financial_integrity(p_order_id);
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments WHERE order_id = p_order_id;
  IF v_paid < v_order.total_amount THEN
    RAISE EXCEPTION 'Pembayaran belum menutupi total (terbayar % dari %)',
      v_paid, v_order.total_amount USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders SET status = 'paid', updated_at = now()
  WHERE id = p_order_id AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');
  RETURN jsonb_build_object('status', 'paid', 'paid_total', v_paid,
                            'order_total', v_order.total_amount);
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_split_payment(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_split_payment(UUID) TO authenticated;

-- ── 10. Trigger status internal untuk RPC approval lama ─────────────────────
-- RPC void/refund lama tetap menjadi jalur mobile. Ia mendapat izin status lewat
-- flag transaksi yang hanya bisa di-set oleh SECURITY DEFINER function.
CREATE OR REPLACE FUNCTION public.void_order_with_approval(
  p_order UUID, p_reason TEXT, p_approver_pin TEXT, p_approver_id UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_approver_id UUID; v_name TEXT; v_outlet UUID; v_status public.order_status;
BEGIN
  IF p_approver_id IS NULL THEN RAISE EXCEPTION 'approver_id wajib diisi'; END IF;
  SELECT outlet_id, status INTO v_outlet, v_status FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status = 'paid' THEN RAISE EXCEPTION 'Order sudah dibayar — gunakan Refund'; END IF;
  IF v_status IN ('void', 'cancelled') THEN RAISE EXCEPTION 'Order sudah dibatalkan'; END IF;
  SELECT public._find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;
  IF v_approver_id IS NULL THEN RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'; END IF;
  SELECT full_name INTO v_name FROM public.profiles WHERE id = v_approver_id;
  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders SET status = 'void', void_reason = p_reason,
    approved_by = v_approver_id, updated_at = now() WHERE id = p_order;
  PERFORM public.restore_stock_for_order(p_order);
  RETURN QUERY SELECT v_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_order_with_approval(
  p_order UUID, p_reason TEXT, p_approver_pin TEXT, p_approver_id UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_approver_id UUID; v_name TEXT; v_outlet UUID; v_status public.order_status;
BEGIN
  IF p_approver_id IS NULL THEN RAISE EXCEPTION 'approver_id wajib diisi'; END IF;
  SELECT outlet_id, status INTO v_outlet, v_status FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan refund';
  END IF;
  SELECT public._find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;
  IF v_approver_id IS NULL THEN RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'; END IF;
  SELECT full_name INTO v_name FROM public.profiles WHERE id = v_approver_id;
  PERFORM set_config('app.order_status_mutation', 'on', true);
  UPDATE public.orders SET status = 'cancelled', void_reason = p_reason,
    approved_by = v_approver_id, updated_at = now() WHERE id = p_order;
  PERFORM public.restore_stock_for_order(p_order);
  RETURN QUERY SELECT v_name;
END;
$$;

COMMENT ON FUNCTION public.guard_order_direct_mutation() IS
  'Mencegah direct REST update status/nominal order; RPC resmi memasang flag lokal.';

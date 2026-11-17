-- 190_menu_item_price_override.sql
--
-- Owner dapat mengizinkan harga jual produk tertentu diubah oleh kasir.
-- Default false menjaga seluruh menu lama tetap memakai harga katalog.
-- Semua jalur POS (online, offline replay, open bill, edit online) tetap
-- melewati validasi finansial server; self-order tetap memakai harga katalog
-- otoritatif dari create_self_order.

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS allow_price_override BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.menu_items.allow_price_override IS
  'Jika true, kasir terautentikasi boleh menentukan harga dasar positif saat transaksi POS.';

-- Trigger awal berjalan sebelum opsi ekstra disisipkan. Untuk menu harga tetap,
-- pertahankan batas bawah katalog; validasi persis katalog+variant+extra tetap
-- dilakukan validate_order_financial_integrity setelah seluruh item tersimpan.
CREATE OR REPLACE FUNCTION public.validate_order_item_price()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_catalog_price NUMERIC;
  v_allow_price_override BOOLEAN;
BEGIN
  SELECT price, allow_price_override
    INTO v_catalog_price, v_allow_price_override
  FROM public.menu_items
  WHERE id = NEW.menu_item_id;

  IF v_catalog_price IS NULL THEN
    RAISE EXCEPTION 'Menu item tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  IF v_allow_price_override THEN
    IF NEW.unit_price <= 0 THEN
      RAISE EXCEPTION 'Harga kasir harus lebih dari nol' USING ERRCODE = '22023';
    END IF;
  ELSIF NEW.unit_price < v_catalog_price THEN
    RAISE EXCEPTION 'unit_price tidak valid (% < harga katalog %)',
      NEW.unit_price, v_catalog_price USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

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
  v_price_allowed BOOLEAN;
  v_variants JSONB;
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
    SELECT oi.*, mi.outlet_id AS menu_outlet_id,
           mi.price AS catalog_price, mi.variants AS catalog_variants,
           mi.allow_price_override
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

    IF v_item.allow_price_override THEN
      -- Hanya menu yang diaktifkan owner boleh memakai harga kasir. Harga
      -- tetap wajib positif; subtotal dan total order divalidasi di bawah.
      v_price_allowed := v_item.unit_price > (v_min_unit - v_item.catalog_price);
    ELSE
      -- Tanpa variant, harga harus tepat katalog + ekstra. Bila menu memiliki
      -- variant, harga harus sama dengan salah satu addition yang dikonfigurasi.
      v_variants := CASE
        WHEN jsonb_typeof(v_item.catalog_variants) = 'array'
          THEN v_item.catalog_variants
        ELSE '[]'::JSONB
      END;
      v_price_allowed := abs(v_item.unit_price - v_min_unit) <= 0.01;
      IF NOT v_price_allowed AND jsonb_array_length(v_variants) > 0 THEN
        SELECT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(v_variants) variant
          WHERE abs(
            v_item.unit_price - v_min_unit
            - COALESCE((variant->>'price_addition')::NUMERIC, 0)
          ) <= 0.01
        ) INTO v_price_allowed;
      END IF;
    END IF;
    IF NOT v_price_allowed THEN
      RAISE EXCEPTION
        'Harga item tidak sesuai katalog, ekstra, atau variant yang tersedia'
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

COMMENT ON FUNCTION public.validate_order_financial_integrity(UUID) IS
  'Memastikan total order dan harga item cocok dengan katalog, ekstra, variant, atau izin harga kasir.';

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
  v_allow_price_override BOOLEAN;
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

    SELECT price, allow_price_override
      INTO v_base, v_allow_price_override
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
    IF v_allow_price_override THEN
      IF v_unit <= v_extra_total THEN
        RAISE EXCEPTION 'Harga kasir harus lebih dari nol' USING ERRCODE = '22023';
      END IF;
    ELSIF v_unit < v_base + v_extra_total THEN
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
  'Membuat order POS + item + extra secara atomik dan idempoten, termasuk harga kasir yang diizinkan per menu.';

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
  v_allow_price_override BOOLEAN;
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
    SELECT price, allow_price_override
      INTO v_base, v_allow_price_override FROM public.menu_items
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
    IF v_allow_price_override THEN
      IF v_unit <= v_extra_total THEN
        RAISE EXCEPTION 'Harga kasir harus lebih dari nol' USING ERRCODE = '22023';
      END IF;
    ELSIF v_unit < v_base + v_extra_total THEN
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

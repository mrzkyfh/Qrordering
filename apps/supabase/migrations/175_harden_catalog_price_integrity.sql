-- 175_harden_catalog_price_integrity.sql
--
-- Order POS sebelumnya hanya menolak harga di bawah katalog. Akibatnya client
-- authenticated dapat mengirim harga arbitrer yang lebih tinggi, padahal harga
-- tambahan yang sah hanya berasal dari opsi menu dan variant yang dikonfigurasi.
-- Validasi di satu titik finansial ini mencakup create POS, open bill, edit
-- self-order, dan pembayaran; harga yang lebih tinggi tanpa konfigurasi ditolak.

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
           mi.price AS catalog_price, mi.variants AS catalog_variants
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

    -- Tanpa variant, harga harus tepat katalog + ekstra. Bila menu memiliki
    -- variant, harga harus sama dengan salah satu addition yang dikonfigurasi.
    -- Ini tetap kompatibel dengan order lama yang belum menyimpan nama variant.
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
  'Memastikan total order dan harga item cocok dengan katalog, ekstra, serta variant yang dikonfigurasi.';

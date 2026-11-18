-- Publikasi promo produk berdasarkan token meja dan validasi diskon final.
CREATE OR REPLACE FUNCTION public.get_public_product_promos(p_token TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', promo.id, 'name', promo.name, 'type', promo.type,
    'value', promo.value, 'max_discount', promo.max_discount,
    'start_date', promo.start_date, 'end_date', promo.end_date,
    'menu_item_ids', COALESCE((SELECT jsonb_agg(pp.menu_item_id) FROM public.promo_products pp WHERE pp.promo_id = promo.id), '[]'::jsonb)
  ) ORDER BY promo.created_at DESC), '[]'::jsonb)
  FROM public.restaurant_tables table_row
  JOIN public.promos promo ON promo.outlet_id = table_row.outlet_id
  WHERE table_row.qr_token = p_token AND table_row.is_active
    AND promo.is_active
    AND (promo.start_date IS NULL OR promo.start_date <= public.jkt_today())
    AND (promo.end_date IS NULL OR promo.end_date >= public.jkt_today())
    AND (promo.usage_limit IS NULL OR promo.usage_count < promo.usage_limit)
    AND EXISTS (SELECT 1 FROM public.promo_products pp WHERE pp.promo_id = promo.id)
$$;
REVOKE ALL ON FUNCTION public.get_public_product_promos(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_product_promos(TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.validate_order_product_promo(p_order_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_promo public.promos%ROWTYPE;
  v_eligible NUMERIC := 0;
  v_expected NUMERIC := 0;
  v_restricted BOOLEAN := false;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR v_order.promo_id IS NULL THEN RETURN; END IF;
  SELECT * INTO v_promo FROM public.promos WHERE id = v_order.promo_id;
  IF NOT FOUND OR v_promo.outlet_id IS DISTINCT FROM v_order.outlet_id THEN
    RAISE EXCEPTION 'Promo order tidak valid' USING ERRCODE = '23514';
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.promo_products WHERE promo_id = v_promo.id) INTO v_restricted;
  IF v_restricted THEN
    SELECT COALESCE(sum(item.subtotal), 0) INTO v_eligible
    FROM public.order_items item JOIN public.promo_products pp
      ON pp.menu_item_id = item.menu_item_id AND pp.promo_id = v_promo.id
    WHERE item.order_id = v_order.id;
  ELSE
    v_eligible := v_order.subtotal;
  END IF;
  IF v_eligible <= 0 THEN RAISE EXCEPTION 'Keranjang tidak memiliki produk promo' USING ERRCODE = '23514'; END IF;
  IF v_promo.type = 'percentage' THEN
    v_expected := round(v_eligible * v_promo.value / 100, 0);
    IF v_promo.max_discount IS NOT NULL THEN v_expected := least(v_expected, v_promo.max_discount); END IF;
  ELSIF v_promo.type = 'fixed' THEN
    v_expected := least(v_promo.value, v_eligible);
  ELSE
    v_expected := 0;
  END IF;
  IF v_order.discount_amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Nilai diskon promo tidak sesuai (diharapkan %, diterima %)', v_expected, v_order.discount_amount USING ERRCODE = '23514';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.validate_order_product_promo(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_order_product_promo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.validate_order_product_promo(CASE WHEN TG_TABLE_NAME = 'orders' THEN COALESCE(NEW.id, OLD.id) ELSE COALESCE(NEW.order_id, OLD.order_id) END);
  RETURN COALESCE(NEW, OLD);
END;
$$;
DROP TRIGGER IF EXISTS trg_validate_order_product_promo_order ON public.orders;
CREATE CONSTRAINT TRIGGER trg_validate_order_product_promo_order
AFTER INSERT OR UPDATE OF promo_id, discount_amount, subtotal ON public.orders
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_order_product_promo();
DROP TRIGGER IF EXISTS trg_validate_order_product_promo_item ON public.order_items;
CREATE CONSTRAINT TRIGGER trg_validate_order_product_promo_item
AFTER INSERT OR UPDATE OR DELETE ON public.order_items
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_order_product_promo();

-- Overload atomik untuk checkout menu QR dengan promo produk otomatis. Nominal
-- diskon tidak pernah diterima dari browser; seluruh harga dihitung ulang dari
-- order_items yang sudah divalidasi oleh create_self_order utama.
CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id       UUID,
  p_table_id        UUID,
  p_items           JSONB,
  p_table_token     TEXT,
  p_customer_name   TEXT,
  p_notes           TEXT,
  p_promo_code      TEXT,
  p_member_phone    TEXT,
  p_request_id      UUID,
  p_product_promo_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_created JSONB;
  v_order public.orders%ROWTYPE;
  v_promo public.promos%ROWTYPE;
  v_eligible NUMERIC := 0;
  v_discount NUMERIC := 0;
  v_tax NUMERIC := 0;
  v_tax_inclusive BOOLEAN := false;
  v_service NUMERIC := 0;
  v_total NUMERIC := 0;
BEGIN
  IF p_product_promo_id IS NOT NULL AND NULLIF(btrim(COALESCE(p_promo_code, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'Pilih promo produk atau kode voucher, bukan keduanya'
      USING ERRCODE = '22023';
  END IF;

  v_created := public.create_self_order(
    p_outlet_id => p_outlet_id, p_table_id => p_table_id,
    p_items => p_items, p_table_token => p_table_token,
    p_customer_name => p_customer_name, p_notes => p_notes,
    p_promo_code => p_promo_code, p_member_phone => p_member_phone,
    p_request_id => p_request_id
  );
  IF p_product_promo_id IS NULL THEN RETURN v_created; END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE id = NULLIF(v_created->>'order_id', '')::UUID FOR UPDATE;
  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM p_outlet_id
     OR v_order.table_id IS DISTINCT FROM p_table_id THEN
    RAISE EXCEPTION 'Order hasil tidak valid' USING ERRCODE = 'P0001';
  END IF;

  -- Replay idempoten mengembalikan hasil yang telah dihitung sebelumnya.
  IF v_order.promo_id = p_product_promo_id AND v_order.discount_amount > 0 THEN
    RETURN v_created || jsonb_build_object(
      'promo_id', v_order.promo_id, 'discount_amount', v_order.discount_amount,
      'total_amount', v_order.total_amount
    );
  END IF;
  IF v_order.promo_id IS NOT NULL OR v_order.discount_amount > 0 THEN
    RAISE EXCEPTION 'Order sudah menggunakan promo lain' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_promo FROM public.promos
  WHERE id = p_product_promo_id FOR UPDATE;
  IF NOT FOUND OR v_promo.outlet_id IS DISTINCT FROM p_outlet_id
     OR NOT v_promo.is_active
     OR (v_promo.start_date IS NOT NULL AND v_promo.start_date > public.jkt_today())
     OR (v_promo.end_date IS NOT NULL AND v_promo.end_date < public.jkt_today())
     OR (v_promo.usage_limit IS NOT NULL AND v_promo.usage_count >= v_promo.usage_limit) THEN
    RAISE EXCEPTION 'Promo produk tidak aktif atau sudah habis' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(sum(oi.subtotal), 0) INTO v_eligible
  FROM public.order_items oi
  JOIN public.promo_products pp
    ON pp.menu_item_id = oi.menu_item_id AND pp.promo_id = v_promo.id
  WHERE oi.order_id = v_order.id;
  IF v_eligible <= 0 THEN
    RAISE EXCEPTION 'Keranjang tidak memiliki produk promo' USING ERRCODE = '22023';
  END IF;

  IF v_promo.type = 'percentage' THEN
    v_discount := round(v_eligible * v_promo.value / 100, 0);
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := least(v_discount, v_promo.max_discount);
    END IF;
  ELSIF v_promo.type = 'fixed' THEN
    v_discount := least(v_promo.value, v_eligible);
  ELSE
    RAISE EXCEPTION 'Jenis promo produk belum didukung' USING ERRCODE = '22023';
  END IF;

  SELECT tax_amount, tax_inclusive, service_charge
    INTO v_tax, v_tax_inclusive, v_service
  FROM public.calculate_server_order_totals(
    v_order.outlet_id, v_order.order_type, v_order.subtotal,
    v_discount, v_order.loyalty_discount
  );
  v_total := greatest(0, v_order.subtotal - v_discount - v_order.loyalty_discount)
    + CASE WHEN v_tax_inclusive THEN 0 ELSE v_tax END + v_service;
  IF v_order.rounding > 0 THEN
    v_total := round(v_total / v_order.rounding) * v_order.rounding;
  END IF;

  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders SET
    promo_id = v_promo.id, discount_amount = v_discount,
    tax_amount = v_tax, tax_inclusive = v_tax_inclusive,
    service_charge = v_service, total_amount = v_total, updated_at = now()
  WHERE id = v_order.id;
  UPDATE public.promos SET usage_count = usage_count + 1 WHERE id = v_promo.id;
  PERFORM public.validate_order_financial_integrity(v_order.id);
  PERFORM public.validate_order_product_promo(v_order.id);

  RETURN v_created || jsonb_build_object(
    'promo_id', v_promo.id, 'promo_name', v_promo.name,
    'discount_amount', v_discount, 'total_amount', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) TO anon, authenticated;

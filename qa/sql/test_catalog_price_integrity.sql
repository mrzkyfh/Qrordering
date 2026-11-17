-- Regression: POS tidak boleh mengubah harga item di atas katalog secara
-- arbitrer; variant yang memang terdaftar tetap sah.
BEGIN;

CREATE TEMP TABLE _catalog_price_results (
  test_case TEXT,
  expected TEXT,
  actual TEXT,
  status TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_outlet UUID;
  v_plain UUID;
  v_variant UUID;
  v_flexible UUID;
  v_order UUID;
  v_order_variant UUID;
  v_order_flexible UUID;
  v_error TEXT;
BEGIN
  PERFORM set_config('app.order_financial_mutation', 'on', true);
  INSERT INTO public.outlets(name) VALUES ('[QA] Price Integrity') RETURNING id INTO v_outlet;
  INSERT INTO public.menu_items(outlet_id, name, price)
    VALUES (v_outlet, '[QA] Plain Menu', 25000) RETURNING id INTO v_plain;
  INSERT INTO public.menu_items(outlet_id, name, price, variants)
    VALUES (
      v_outlet,
      '[QA] Variant Menu',
      25000,
      '[{"name":"Large","price_addition":5000}]'::jsonb
    ) RETURNING id INTO v_variant;
  INSERT INTO public.menu_items(outlet_id, name, price, allow_price_override)
    VALUES (v_outlet, '[QA] Flexible Price Menu', 25000, TRUE)
    RETURNING id INTO v_flexible;

  INSERT INTO public.orders(outlet_id, order_number, status, subtotal, total_amount)
    VALUES (v_outlet, '[QA]-PRICE-1', 'confirmed', 26000, 26000)
    RETURNING id INTO v_order;
  INSERT INTO public.order_items(order_id, menu_item_id, quantity, unit_price, subtotal)
    VALUES (v_order, v_plain, 1, 26000, 26000);

  BEGIN
    PERFORM public.validate_order_financial_integrity(v_order);
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-01', 'harga arbitrer ditolak', 'tidak ditolak', '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-01', 'harga arbitrer ditolak', v_error, '✅ PASS'
    );
  END;

  INSERT INTO public.orders(outlet_id, order_number, status, subtotal, total_amount)
    VALUES (v_outlet, '[QA]-PRICE-2', 'confirmed', 30000, 30000)
    RETURNING id INTO v_order_variant;
  INSERT INTO public.order_items(order_id, menu_item_id, quantity, unit_price, subtotal)
    VALUES (v_order_variant, v_variant, 1, 30000, 30000);

  BEGIN
    PERFORM public.validate_order_financial_integrity(v_order_variant);
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-02', 'variant terdaftar diterima', 'diterima', '✅ PASS'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-02', 'variant terdaftar diterima', v_error, '❌ FAIL'
    );
  END;

  INSERT INTO public.orders(outlet_id, order_number, status, subtotal, total_amount)
    VALUES (v_outlet, '[QA]-PRICE-3', 'confirmed', 18000, 18000)
    RETURNING id INTO v_order_flexible;
  INSERT INTO public.order_items(order_id, menu_item_id, quantity, unit_price, subtotal)
    VALUES (v_order_flexible, v_flexible, 1, 18000, 18000);

  BEGIN
    PERFORM public.validate_order_financial_integrity(v_order_flexible);
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-03', 'harga kasir pada menu fleksibel diterima', 'diterima', '✅ PASS'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _catalog_price_results VALUES (
      'PRICE-03', 'harga kasir pada menu fleksibel diterima', v_error, '❌ FAIL'
    );
  END;
END $$;

SELECT * FROM _catalog_price_results ORDER BY test_case;
SELECT CASE
  WHEN count(*) FILTER (WHERE status = '❌ FAIL') = 0
  THEN '✅ ALL CATALOG PRICE TESTS PASSED'
  ELSE '❌ CATALOG PRICE TEST FAILED'
END AS summary
FROM _catalog_price_results;

ROLLBACK;

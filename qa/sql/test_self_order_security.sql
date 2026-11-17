-- ============================================================
-- TEST SUITE: Self-order security contract / negative tests
-- Semua fixture dan order uji di-ROLLBACK di akhir script.
-- Jalankan dengan Supabase SQL Editor atau:
--   supabase db query --linked --file qa/sql/test_self_order_security.sql
-- ============================================================

BEGIN;

CREATE TEMP TABLE _self_order_security_results (
  tc TEXT,
  skenario TEXT,
  ekspektasi TEXT,
  aktual TEXT,
  status TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_outlet UUID;
  v_table UUID;
  v_menu UUID;
  v_token TEXT := 'qa-self-order-token-' || gen_random_uuid()::TEXT;
  v_price NUMERIC := 42000;
  v_result JSONB;
  v_order_id UUID;
  v_subtotal NUMERIC;
  v_public_api_count INTEGER;
  v_anon_api_count INTEGER;
  v_internal_anon_count INTEGER;
  v_has_trigger BOOLEAN;
  v_hidden_published BOOLEAN;
BEGIN
  -- Kontrak API: hanya signature idempoten 10 argumen yang boleh dipanggil anon.
  SELECT count(*) INTO v_public_api_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_self_order'
    AND p.pronargs = 10;

  SELECT count(*) INTO v_anon_api_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_self_order'
    AND p.pronargs = 10
    AND has_function_privilege('anon', p.oid, 'EXECUTE');

  SELECT count(*) INTO v_internal_anon_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_self_order'
    AND oidvectortypes(p.proargtypes) IN (
      'uuid, uuid, jsonb, text, text, text, uuid, integer',
      'uuid, uuid, jsonb, text, text, text, text, uuid, integer'
    )
    AND has_function_privilege('anon', p.oid, 'EXECUTE');

  INSERT INTO _self_order_security_results VALUES (
    'RPC-01', 'Self-order memiliki satu signature publik idempoten (10 argumen)',
    '1 signature', v_public_api_count || ' signature',
    CASE WHEN v_public_api_count = 1 THEN '✅ PASS' ELSE '❌ FAIL' END
  );
  INSERT INTO _self_order_security_results VALUES (
    'RPC-02', 'Signature idempoten dapat dipanggil anon',
    '1 grant anon', v_anon_api_count || ' grant',
    CASE WHEN v_anon_api_count = 1 THEN '✅ PASS' ELSE '❌ FAIL' END
  );
  INSERT INTO _self_order_security_results VALUES (
    'RPC-03', 'Signature legacy tidak dapat dipanggil anon',
    '0 grant legacy', v_internal_anon_count || ' grant',
    CASE WHEN v_internal_anon_count = 0 THEN '✅ PASS' ELSE '❌ FAIL' END
  );

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'orders'
      AND t.tgname = 'trg_guard_anon_self_order_loyalty'
      AND NOT t.tgisinternal
  ) INTO v_has_trigger;
  INSERT INTO _self_order_security_results VALUES (
    'RPC-04', 'Trigger menolak redeem loyalty anonim pada self-order',
    'trigger ada', CASE WHEN v_has_trigger THEN 'ada' ELSE 'tidak ada' END,
    CASE WHEN v_has_trigger THEN '✅ PASS' ELSE '❌ FAIL' END
  );

  -- Fixture disposable. Tidak pernah committed.
  INSERT INTO outlets(name, is_active)
  VALUES ('[QA-AUDIT] self-order security', true)
  RETURNING id INTO v_outlet;
  INSERT INTO restaurant_tables(outlet_id, table_number, qr_token, is_active)
  VALUES (v_outlet, '[QA-AUDIT]', v_token, true)
  RETURNING id INTO v_table;
  INSERT INTO menu_items(outlet_id, name, price, is_active, is_available)
  VALUES (v_outlet, '[QA-AUDIT] authoritative price', v_price, true, true)
  RETURNING id INTO v_menu;

  -- Unit price palsu = 0. Server harus memakai harga katalog Rp42.000.
  v_result := public.create_self_order(
    p_outlet_id => v_outlet,
    p_table_id => v_table,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1,
      'unit_price', 0,
      'options', '[]'::jsonb
    )),
    p_table_token => v_token,
    p_customer_name => '[QA-AUDIT]',
    p_notes => NULL,
    p_promo_code => NULL,
    p_member_id => NULL,
    p_redeem_points => 0,
    p_request_id => gen_random_uuid()
  );
  v_order_id := NULLIF(v_result->>'order_id', '')::UUID;
  SELECT subtotal INTO v_subtotal FROM orders WHERE id = v_order_id;
  INSERT INTO _self_order_security_results VALUES (
    'RPC-05', 'Harga item dari server, bukan unit_price klien',
    v_price::TEXT, COALESCE(v_subtotal::TEXT, 'NULL'),
    CASE WHEN v_subtotal = v_price THEN '✅ PASS' ELSE '❌ FAIL' END
  );

  -- Produk yang disembunyikan owner tidak boleh dipesan dengan memalsukan ID.
  UPDATE menu_items SET show_in_qr_menu = false WHERE id = v_menu;
  BEGIN
    PERFORM public._self_order_line(
      v_outlet,
      jsonb_build_object(
        'menu_item_id', v_menu, 'quantity', 1, 'unit_price', v_price
      )
    );
    INSERT INTO _self_order_security_results VALUES (
      'RPC-06', 'Menu tersembunyi dari QR ditolak server', 'exception',
      'request berhasil', '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _self_order_security_results VALUES (
      'RPC-06', 'Menu tersembunyi dari QR ditolak server', 'exception',
      SQLSTATE || ': ' || SQLERRM, '✅ PASS'
    );
  END;

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      COALESCE(public.get_public_menu_snapshot(v_token)->'menu', '[]'::JSONB)
    ) published_menu
    WHERE published_menu->>'id' = v_menu::TEXT
  ) INTO v_hidden_published;
  INSERT INTO _self_order_security_results VALUES (
    'RPC-07', 'Menu tersembunyi tidak diterbitkan pada snapshot QR',
    'tidak diterbitkan',
    CASE WHEN v_hidden_published THEN 'masih diterbitkan' ELSE 'tidak diterbitkan' END,
    CASE WHEN v_hidden_published THEN '❌ FAIL' ELSE '✅ PASS' END
  );
  UPDATE menu_items SET show_in_qr_menu = true WHERE id = v_menu;

  -- Token QR salah wajib ditolak sebelum order dibuat.
  BEGIN
    PERFORM public.create_self_order(
      p_outlet_id => v_outlet,
      p_table_id => v_table,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu, 'quantity', 1, 'unit_price', v_price
      )),
      p_table_token => 'token-salah',
      p_customer_name => '[QA-AUDIT]',
      p_notes => NULL,
      p_promo_code => NULL,
      p_member_id => NULL,
      p_redeem_points => 0,
      p_request_id => gen_random_uuid()
    );
    INSERT INTO _self_order_security_results VALUES (
      'RPC-08', 'Token QR salah ditolak', 'exception 42501', 'request berhasil', '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _self_order_security_results VALUES (
      'RPC-08', 'Token QR salah ditolak', 'exception 42501', SQLSTATE || ': ' || SQLERRM,
      CASE WHEN SQLSTATE = '42501' THEN '✅ PASS' ELSE '⚠️ INFO' END
    );
  END;
END;
$$;

SELECT tc AS "Test Case", skenario AS "Skenario",
       ekspektasi AS "Ekspektasi", aktual AS "Aktual", status AS "Status"
FROM _self_order_security_results
UNION ALL
SELECT 'RINGKASAN',
       COUNT(*) FILTER (WHERE status LIKE '✅%') || ' PASS | ' ||
       COUNT(*) FILTER (WHERE status LIKE '❌%') || ' FAIL | ' ||
       COUNT(*) FILTER (WHERE status LIKE '⚠️%') || ' INFO',
       'TOTAL: ' || COUNT(*), '',
       CASE WHEN COUNT(*) FILTER (WHERE status LIKE '❌%') = 0
            THEN '✅ SEMUA LULUS' ELSE '❌ ADA KEGAGALAN' END
FROM _self_order_security_results;

ROLLBACK;

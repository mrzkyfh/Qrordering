-- Regression transaksi online/replay-offline lintas role.
-- Aman dijalankan pada database terhubung: semua fixture di-ROLLBACK.

BEGIN;

CREATE TEMP TABLE _transaction_role_results (
  test_case TEXT PRIMARY KEY,
  mode TEXT NOT NULL,
  actor_role TEXT NOT NULL,
  expected TEXT NOT NULL,
  actual TEXT NOT NULL,
  status TEXT NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_outlet_a UUID;
  v_outlet_b UUID;
  v_menu_a UUID;
  v_menu_b UUID;
  v_owner UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_manager UUID := gen_random_uuid();
  v_cashier UUID := gen_random_uuid();
  v_kitchen UUID := gen_random_uuid();
  v_customer UUID := gen_random_uuid();
  v_cashier_no_replacement UUID := gen_random_uuid();
  v_users UUID[];
  v_roles TEXT[] := ARRAY[
    'owner', 'admin', 'manajer', 'kasir', 'dapur', 'pelanggan', 'kasir'
  ];
  v_shifts UUID[] := ARRAY[]::UUID[];
  v_shift UUID;
  v_shift_b UUID;
  v_old_shift UUID;
  v_closed_shift UUID;
  v_no_replacement_shift UUID;
  v_order UUID;
  v_order_total NUMERIC;
  v_result JSONB;
  v_error TEXT;
  v_state TEXT;
  v_i INTEGER;
  v_paid NUMERIC;
BEGIN
  v_users := ARRAY[
    v_owner, v_admin, v_manager, v_cashier, v_kitchen, v_customer,
    v_cashier_no_replacement
  ];

  INSERT INTO public.outlets(name)
  VALUES ('[QA] Role Matrix A') RETURNING id INTO v_outlet_a;
  INSERT INTO public.outlets(name)
  VALUES ('[QA] Role Matrix B') RETURNING id INTO v_outlet_b;

  INSERT INTO public.menu_items(outlet_id, name, price)
  VALUES (v_outlet_a, '[QA] Menu A', 10000) RETURNING id INTO v_menu_a;
  INSERT INTO public.menu_items(outlet_id, name, price)
  VALUES (v_outlet_b, '[QA] Menu B', 12000) RETURNING id INTO v_menu_b;

  FOR v_i IN 1..array_length(v_users, 1) LOOP
    INSERT INTO auth.users(
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_users[v_i], 'authenticated', 'authenticated',
      format('qa-role-%s-%s@qrordering.invalid', v_roles[v_i], v_users[v_i]),
      '', now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', '[QA] ' || v_roles[v_i]),
      now(), now()
    );

    UPDATE public.profiles
    SET outlet_id = v_outlet_a,
        role = v_roles[v_i]::public.user_role,
        is_active = true
    WHERE id = v_users[v_i];
  END LOOP;

  -- Shift aktif untuk role yang boleh bertransaksi.
  FOR v_i IN 1..4 LOOP
    INSERT INTO public.shifts(outlet_id, kasir_id, start_time, opening_cash)
    VALUES (v_outlet_a, v_users[v_i], now() - interval '2 hours', 0)
    RETURNING id INTO v_shift;
    v_shifts := array_append(v_shifts, v_shift);
  END LOOP;

  INSERT INTO public.shifts(outlet_id, kasir_id, start_time, opening_cash)
  VALUES (v_outlet_b, v_owner, now() - interval '2 hours', 0)
  RETURNING id INTO v_shift_b;

  INSERT INTO public.shifts(
    outlet_id, kasir_id, start_time, end_time, opening_cash
  ) VALUES (
    v_outlet_a, v_cashier,
    now() - interval '3 days', now() - interval '2 days', 0
  ) RETURNING id INTO v_old_shift;

  INSERT INTO public.shifts(
    outlet_id, kasir_id, start_time, end_time, opening_cash
  ) VALUES (
    v_outlet_a, v_owner,
    now() - interval '4 hours', now() - interval '3 hours', 0
  ) RETURNING id INTO v_closed_shift;

  INSERT INTO public.shifts(
    outlet_id, kasir_id, start_time, end_time, opening_cash
  ) VALUES (
    v_outlet_a, v_cashier_no_replacement,
    now() - interval '2 days', now() - interval '1 day', 0
  ) RETURNING id INTO v_no_replacement_shift;

  -- ONLINE: owner/admin/manajer/kasir membuat dan melunasi order secara sah.
  FOR v_i IN 1..4 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      v_order := gen_random_uuid();
      v_result := public.create_pos_order(
        p_outlet_id => v_outlet_a,
        p_order_type => 'dine_in'::public.order_type,
        p_status => 'confirmed'::public.order_status,
        p_items => jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
          'extras', '[]'::jsonb
        )),
        p_created_by => v_users[v_i],
        p_shift_id => v_shifts[v_i],
        p_order_id => v_order,
        p_local_receipt_no => 'QA-ROLE-ALLOW-' || v_i
      );
      v_order_total := (v_result->>'total_amount')::NUMERIC;
      v_result := public.record_pos_payment_with_context(
        v_order, v_outlet_a, v_shifts[v_i], true,
        'cash'::public.payment_method, v_order_total,
        NULL, 'qa-role-allow-' || v_i, true, now()
      );
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-ALLOW-' || v_i, 'online', v_roles[v_i],
        'order dan payment diterima',
        COALESCE(v_result->>'status', 'null'),
        CASE WHEN v_result->>'status' = 'paid' THEN 'PASS' ELSE 'FAIL' END
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-ALLOW-' || v_i, 'online', v_roles[v_i],
        'order dan payment diterima', v_state || ': ' || v_error, 'FAIL'
      );
    END;
  END LOOP;

  -- OFFLINE-REPLAY: role sah tetap diterima setelah reconnect. Timestamp asli
  -- dipertahankan agar server menguji rentang till pada waktu transaksi.
  FOR v_i IN 1..4 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      v_order := gen_random_uuid();
      v_result := public.create_pos_order(
        p_outlet_id => v_outlet_a,
        p_order_type => 'takeaway'::public.order_type,
        p_status => 'confirmed'::public.order_status,
        p_items => jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
          'extras', '[]'::jsonb
        )),
        p_created_by => v_users[v_i],
        p_shift_id => v_shifts[v_i],
        p_order_id => v_order,
        p_created_at => now() - interval '30 minutes',
        p_local_receipt_no => 'QA-ROLE-OFFLINE-' || v_i
      );
      v_order_total := (v_result->>'total_amount')::NUMERIC;
      v_result := public.record_pos_payment_with_context(
        v_order, v_outlet_a, v_shifts[v_i], true,
        'qris'::public.payment_method, v_order_total,
        NULL, 'qa-role-offline-pay-' || v_i, true,
        now() - interval '30 minutes'
      );
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-OFFLINE-ALLOW-' || v_i, 'offline-replay', v_roles[v_i],
        'order dan payment replay diterima',
        COALESCE(v_result->>'status', 'null'),
        CASE WHEN v_result->>'status' = 'paid' THEN 'PASS' ELSE 'FAIL' END
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-OFFLINE-ALLOW-' || v_i, 'offline-replay', v_roles[v_i],
        'order dan payment replay diterima',
        v_state || ': ' || v_error, 'FAIL'
      );
    END;
  END LOOP;

  -- OFFLINE-REPLAY: menyimpan payload secara lokal tidak memberi role dapur
  -- atau pelanggan hak POS baru ketika payload akhirnya sampai ke server.
  FOR v_i IN 5..6 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      PERFORM public.create_pos_order(
        p_outlet_id => v_outlet_a,
        p_order_type => 'takeaway'::public.order_type,
        p_status => 'confirmed'::public.order_status,
        p_items => jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
          'extras', '[]'::jsonb
        )),
        p_created_by => v_users[v_i],
        p_order_id => gen_random_uuid(),
        p_created_at => now() - interval '30 minutes',
        p_local_receipt_no => 'QA-ROLE-OFFLINE-DENY-' || v_i
      );
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-OFFLINE-DENY-' || v_i, 'offline-replay', v_roles[v_i],
        'ditolak 42501', 'diterima', 'FAIL'
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-OFFLINE-DENY-' || v_i, 'offline-replay', v_roles[v_i],
        'ditolak 42501', v_state || ': ' || v_error,
        CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
      );
    END;
  END LOOP;

  -- ONLINE: dapur/pelanggan tidak boleh membuat order POS atau menerima bayar.
  FOR v_i IN 5..6 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      PERFORM public.create_pos_order(
        p_outlet_id => v_outlet_a,
        p_order_type => 'dine_in'::public.order_type,
        p_status => 'confirmed'::public.order_status,
        p_items => jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
          'extras', '[]'::jsonb
        )),
        p_created_by => v_users[v_i], p_order_id => gen_random_uuid()
      );
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-DENY-CREATE-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', 'diterima', 'FAIL'
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-DENY-CREATE-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', v_state || ': ' || v_error,
        CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
      );
    END;
  END LOOP;

  -- Buat satu order dasar sebagai owner untuk pengujian payment role ilegal.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );
  v_order := gen_random_uuid();
  v_result := public.create_pos_order(
    p_outlet_id => v_outlet_a,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_owner, p_shift_id => v_shifts[1], p_order_id => v_order
  );
  v_order_total := (v_result->>'total_amount')::NUMERIC;

  FOR v_i IN 5..6 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      PERFORM public.record_pos_payment_with_context(
        v_order, v_outlet_a, v_shifts[1], false,
        'qris'::public.payment_method, v_order_total,
        NULL, 'qa-role-deny-pay-' || v_i, true, now()
      );
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-DENY-PAY-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', 'diterima', 'FAIL'
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'ROLE-DENY-PAY-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', v_state || ': ' || v_error,
        CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
      );
    END;
  END LOOP;

  -- Admin outlet A tidak dapat membuat transaksi outlet B.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_admin, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );
  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_b,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_b, 'quantity', 1, 'unit_price', 12000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_admin, p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'OUTLET-ADMIN-DENY', 'online', 'admin', 'ditolak 42501', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'OUTLET-ADMIN-DENY', 'online', 'admin', 'ditolak 42501',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  -- Owner boleh memilih outlet B secara eksplisit.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );
  BEGIN
    v_result := public.create_pos_order(
      p_outlet_id => v_outlet_b,
      p_order_type => 'takeaway'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_b, 'quantity', 1, 'unit_price', 12000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_owner, p_shift_id => v_shift_b,
      p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'OUTLET-OWNER-ALLOW', 'online', 'owner', 'diterima',
      COALESCE(v_result->>'order_id', 'null'),
      CASE WHEN v_result ? 'order_id' THEN 'PASS' ELSE 'FAIL' END
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'OUTLET-OWNER-ALLOW', 'online', 'owner', 'diterima',
      v_state || ': ' || v_error, 'FAIL'
    );
  END;

  -- Kasir/manajer tidak boleh memakai till user lain.
  FOR v_i IN 3..4 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      PERFORM public.record_pos_payment_with_context(
        v_order, v_outlet_a, v_shifts[1], false,
        'cash'::public.payment_method, v_order_total,
        NULL, 'qa-foreign-till-' || v_i, true, now()
      );
      INSERT INTO _transaction_role_results VALUES (
        'FOREIGN-TILL-DENY-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', 'diterima', 'FAIL'
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'FOREIGN-TILL-DENY-' || v_i, 'online', v_roles[v_i],
        'ditolak 42501', v_state || ': ' || v_error,
        CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
      );
    END;
  END LOOP;

  -- Helper pola uji penolakan payment sebagai owner.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      v_order, v_outlet_a, NULL, false,
      'cash'::public.payment_method, v_order_total,
      NULL, 'qa-null-shift', true, now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'PAY-NO-TILL', 'online', 'owner', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'PAY-NO-TILL', 'online', 'owner', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      v_order, v_outlet_a, v_closed_shift, false,
      'cash'::public.payment_method, v_order_total,
      NULL, 'qa-closed-shift', true, now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'PAY-CLOSED-TILL', 'online', 'owner', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'PAY-CLOSED-TILL', 'online', 'owner', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      v_order, v_outlet_a, v_shifts[1], false,
      'cash'::public.payment_method, 0,
      NULL, 'qa-zero-amount', true, now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'PAY-ZERO', 'online', 'owner', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'PAY-ZERO', 'online', 'owner', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  -- Replay offline order lama: order tetap sah, payment masuk ke till aktif kini.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_cashier, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );
  BEGIN
    v_order := gen_random_uuid();
    v_result := public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_cashier, p_shift_id => v_old_shift,
      p_order_id => v_order,
      p_created_at => now() - interval '2 days 12 hours',
      p_local_receipt_no => 'QA-OLD-UNPAID'
    );
    v_order_total := (v_result->>'total_amount')::NUMERIC;
    v_result := public.record_pos_payment_with_context(
      v_order, v_outlet_a, v_shifts[4], true,
      'qris'::public.payment_method, v_order_total,
      NULL, 'qa-old-unpaid-paid-now', true, now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'OFFLINE-OLD-ORDER-PAY-NOW', 'offline-replay', 'kasir',
      'diterima pada till aktif', COALESCE(v_result->>'status', 'null'),
      CASE WHEN v_result->>'status' = 'paid' THEN 'PASS' ELSE 'FAIL' END
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'OFFLINE-OLD-ORDER-PAY-NOW', 'offline-replay', 'kasir',
      'diterima pada till aktif', v_state || ': ' || v_error, 'FAIL'
    );
  END;

  -- Cache till lama tanpa shift pengganti pada waktu transaksi harus ditolak.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_cashier_no_replacement,
      'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );
  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_cashier_no_replacement,
      p_shift_id => v_no_replacement_shift,
      p_order_id => gen_random_uuid(), p_created_at => now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'OFFLINE-STALE-NO-REPLACEMENT', 'offline-replay', 'kasir',
      'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'OFFLINE-STALE-NO-REPLACEMENT', 'offline-replay', 'kasir',
      'ditolak 22023', v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  -- Manipulasi payload order yang harus ditolak server.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_cashier, 'role', 'authenticated', 'aud', 'authenticated'
    )::text,
    true
  );

  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 1,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_cashier, p_shift_id => v_shifts[4],
      p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-PRICE-TAMPER', 'online', 'kasir', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-PRICE-TAMPER', 'online', 'kasir', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => '[]'::jsonb,
      p_created_by => v_cashier, p_shift_id => v_shifts[4],
      p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-EMPTY', 'online', 'kasir', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-EMPTY', 'online', 'kasir', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'paid'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_cashier, p_shift_id => v_shifts[4],
      p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-INVALID-STATUS', 'online', 'kasir', 'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-INVALID-STATUS', 'online', 'kasir', 'ditolak 22023',
      v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_cashier, p_shift_id => v_shifts[4],
      p_order_id => gen_random_uuid(),
      p_created_at => now() + interval '1 hour'
    );
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-FUTURE-CLOCK', 'offline-replay', 'kasir',
      'ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-FUTURE-CLOCK', 'offline-replay', 'kasir',
      'ditolak 22023', v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet_a,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_admin, p_shift_id => v_shifts[4],
      p_order_id => gen_random_uuid()
    );
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-CREATED-BY-MISMATCH', 'offline-replay', 'kasir',
      'ditolak 42501', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'ORDER-CREATED-BY-MISMATCH', 'offline-replay', 'kasir',
      'ditolak 42501', v_state || ': ' || v_error,
      CASE WHEN v_state = '42501' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  -- Idempotency: retry key sama diterima sebagai duplicate; key baru ditolak.
  v_order := gen_random_uuid();
  v_result := public.create_pos_order(
    p_outlet_id => v_outlet_a,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_cashier, p_shift_id => v_shifts[4], p_order_id => v_order
  );
  v_order_total := (v_result->>'total_amount')::NUMERIC;
  PERFORM public.record_pos_payment_with_context(
    v_order, v_outlet_a, v_shifts[4], true,
    'cash'::public.payment_method, v_order_total,
    NULL, 'qa-idempotent-payment', true, now()
  );
  v_result := public.record_pos_payment_with_context(
    v_order, v_outlet_a, v_shifts[4], true,
    'cash'::public.payment_method, v_order_total,
    NULL, 'qa-idempotent-payment', true, now()
  );
  INSERT INTO _transaction_role_results VALUES (
    'PAY-IDEMPOTENT-RETRY', 'offline-replay', 'kasir',
    'duplicate diterima tanpa pembayaran ganda', v_result::TEXT,
    CASE WHEN COALESCE((v_result->>'duplicate')::BOOLEAN, false)
      THEN 'PASS' ELSE 'FAIL' END
  );

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      v_order, v_outlet_a, v_shifts[4], true,
      'cash'::public.payment_method, v_order_total,
      NULL, 'qa-second-new-payment', true, now()
    );
    INSERT INTO _transaction_role_results VALUES (
      'PAY-ALREADY-PAID', 'online', 'kasir',
      'key baru ditolak 22023', 'diterima', 'FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    INSERT INTO _transaction_role_results VALUES (
      'PAY-ALREADY-PAID', 'online', 'kasir',
      'key baru ditolak 22023', v_state || ': ' || v_error,
      CASE WHEN v_state = '22023' THEN 'PASS' ELSE 'FAIL' END
    );
  END;

  -- Split kurang bayar tidak boleh mengubah status menjadi paid.
  v_order := gen_random_uuid();
  v_result := public.create_pos_order(
    p_outlet_id => v_outlet_a,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu_a, 'quantity', 1, 'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_cashier, p_shift_id => v_shifts[4], p_order_id => v_order
  );
  v_order_total := (v_result->>'total_amount')::NUMERIC;
  PERFORM public.record_pos_payment_with_context(
    v_order, v_outlet_a, v_shifts[4], true,
    'cash'::public.payment_method, 1000,
    NULL, 'qa-split-part-1', false, now()
  );
  v_result := public.record_pos_payment_with_context(
    v_order, v_outlet_a, v_shifts[4], true,
    'qris'::public.payment_method, 1000,
    NULL, 'qa-split-part-2', true, now()
  );
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments WHERE order_id = v_order;
  INSERT INTO _transaction_role_results VALUES (
    'PAY-SPLIT-UNDERPAID', 'online/offline-replay', 'kasir',
    'tetap belum paid',
    format('status=%s paid=%s total=%s', v_result->>'status', v_paid, v_order_total),
    CASE WHEN v_result->>'status' <> 'paid' AND v_paid < v_order_total
      THEN 'PASS' ELSE 'FAIL' END
  );

  -- Kas Masuk/Keluar: owner/admin/manajer boleh, kasir/dapur/pelanggan ditolak.
  FOR v_i IN 1..6 LOOP
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object(
        'sub', v_users[v_i], 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    BEGIN
      PERFORM public.record_cash_movement(
        CASE WHEN v_i <= 4 THEN v_shifts[v_i] ELSE v_shifts[1] END,
        v_outlet_a, 'in', 1000, '[QA] role matrix', NULL
      );
      INSERT INTO _transaction_role_results VALUES (
        'CASH-MOVEMENT-' || v_i, 'online', v_roles[v_i],
        CASE WHEN v_i <= 3 THEN 'diterima' ELSE 'ditolak 42501' END,
        'diterima',
        CASE WHEN v_i <= 3 THEN 'PASS' ELSE 'FAIL' END
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
      INSERT INTO _transaction_role_results VALUES (
        'CASH-MOVEMENT-' || v_i, 'online', v_roles[v_i],
        CASE WHEN v_i <= 3 THEN 'diterima' ELSE 'ditolak 42501' END,
        v_state || ': ' || v_error,
        CASE
          WHEN v_i <= 3 THEN 'FAIL'
          WHEN v_state = '42501' THEN 'PASS'
          ELSE 'FAIL'
        END
      );
    END;
  END LOOP;
END;
$$;

SELECT
  count(*) AS total,
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed
FROM _transaction_role_results;

SELECT *
FROM _transaction_role_results
ORDER BY test_case;

ROLLBACK;

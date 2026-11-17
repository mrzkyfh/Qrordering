-- Regression end-to-end untuk migration 178.
-- Jalankan di Supabase SQL Editor setelah migration diterapkan. Seluruh fixture
-- dibungkus transaksi dan di-ROLLBACK; tidak meninggalkan user/order QA.

BEGIN;

CREATE TEMP TABLE _offline_shift_results (
  test_case TEXT,
  expected TEXT,
  actual TEXT,
  status TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_user UUID := gen_random_uuid();
  v_outlet UUID;
  v_menu UUID;
  v_old_shift UUID;
  v_active_shift UUID;
  v_order UUID := gen_random_uuid();
  v_historical_order UUID := gen_random_uuid();
  v_delayed_order UUID := gen_random_uuid();
  v_payment_validation_order UUID := gen_random_uuid();
  v_tx_time TIMESTAMPTZ := now() - interval '30 minutes';
  v_old_end TIMESTAMPTZ := now() - interval '1 hour';
  v_result JSONB;
  v_saved_shift UUID;
  v_original_shift UUID;
  v_payment_shift UUID;
  v_order_total NUMERIC;
  v_error TEXT;
BEGIN
  INSERT INTO public.outlets(name)
  VALUES ('[QA] Offline Shift Recovery')
  RETURNING id INTO v_outlet;

  INSERT INTO auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_user,
    'authenticated',
    'authenticated',
    'qa-offline-shift-' || v_user || '@qrordering.invalid',
    '',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"QA Offline Shift"}'::jsonb,
    now(),
    now()
  );

  UPDATE public.profiles
  SET outlet_id = v_outlet, role = 'kasir', is_active = true
  WHERE id = v_user;

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_user,
      'role', 'authenticated',
      'aud', 'authenticated'
    )::text,
    true
  );

  INSERT INTO public.menu_items(outlet_id, name, price)
  VALUES (v_outlet, '[QA] Kopi Recovery', 10000)
  RETURNING id INTO v_menu;

  INSERT INTO public.shifts(
    outlet_id, kasir_id, start_time, end_time, opening_cash
  ) VALUES (
    v_outlet,
    v_user,
    now() - interval '2 days',
    v_old_end,
    0
  ) RETURNING id INTO v_old_shift;

  INSERT INTO public.shifts(
    outlet_id, kasir_id, start_time, opening_cash
  ) VALUES (
    v_outlet,
    v_user,
    now() - interval '2 hours',
    0
  ) RETURNING id INTO v_active_shift;

  v_result := public.create_pos_order(
    p_outlet_id => v_outlet,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1,
      'unit_price', 10000,
      'notes', NULL,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_user,
    p_shift_id => v_old_shift,
    p_order_id => v_order,
    p_created_at => v_tx_time,
    p_local_receipt_no => 'QA-RECOVERY-001'
  );

  SELECT shift_id, original_shift_id, total_amount
  INTO v_saved_shift, v_original_shift, v_order_total
  FROM public.orders
  WHERE id = v_order;

  INSERT INTO _offline_shift_results VALUES (
    'SHIFT-RECOVERY-01',
    'order dipetakan ke shift aktif dan shift lama diaudit',
    format('shift=%s original=%s', v_saved_shift, v_original_shift),
    CASE
      WHEN v_saved_shift = v_active_shift AND v_original_shift = v_old_shift
      THEN '✅ PASS'
      ELSE '❌ FAIL'
    END
  );

  v_result := public.record_pos_payment_with_context(
    p_order_id => v_order,
    p_outlet_id => v_outlet,
    p_shift_id => v_old_shift,
    p_force_order_shift => true,
    p_method => 'cash'::public.payment_method,
    p_amount => v_order_total,
    p_idempotency_key => 'qa-recovery-payment-001',
    p_finalize => true,
    p_paid_at => v_tx_time
  );

  SELECT shift_id INTO v_payment_shift
  FROM public.payments
  WHERE order_id = v_order
  ORDER BY paid_at DESC
  LIMIT 1;

  INSERT INTO _offline_shift_results VALUES (
    'SHIFT-RECOVERY-02',
    'payment dan split component memakai shift efektif yang sama',
    format(
      'payment_shift=%s recovered=%s',
      v_payment_shift,
      COALESCE(v_result->>'shift_recovered', 'null')
    ),
    CASE
      WHEN v_payment_shift = v_active_shift
       AND COALESCE((v_result->>'shift_recovered')::BOOLEAN, false)
      THEN '✅ PASS'
      ELSE '❌ FAIL'
    END
  );

  -- paid_at tidak boleh keluar dari rentang till walaupun payload berasal dari
  -- perangkat tepercaya. Ini mencegah salah atribusi rekonsiliasi kas.
  PERFORM public.create_pos_order(
    p_outlet_id => v_outlet,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1,
      'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_user,
    p_shift_id => v_active_shift,
    p_order_id => v_payment_validation_order,
    p_created_at => v_tx_time,
    p_local_receipt_no => 'QA-PAYMENT-TIME-GUARD'
  );

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      p_order_id => v_payment_validation_order,
      p_outlet_id => v_outlet,
      p_shift_id => v_active_shift,
      p_force_order_shift => false,
      p_method => 'cash'::public.payment_method,
      p_amount => 10000,
      p_idempotency_key => 'qa-payment-before-open',
      p_finalize => true,
      p_paid_at => now() - interval '3 hours'
    );
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-07',
      'waktu bayar sebelum till dibuka ditolak',
      'tidak ditolak',
      '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-07',
      'waktu bayar sebelum till dibuka ditolak',
      v_error,
      CASE
        WHEN lower(v_error) LIKE '%sebelum till dibuka%' THEN '✅ PASS'
        ELSE '❌ FAIL'
      END
    );
  END;

  BEGIN
    PERFORM public.record_pos_payment_with_context(
      p_order_id => v_payment_validation_order,
      p_outlet_id => v_outlet,
      p_shift_id => v_active_shift,
      p_force_order_shift => false,
      p_method => 'cash'::public.payment_method,
      p_amount => 10000,
      p_idempotency_key => 'qa-payment-future',
      p_finalize => true,
      p_paid_at => now() + interval '1 hour'
    );
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-08',
      'waktu bayar perangkat masa depan ditolak',
      'tidak ditolak',
      '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-08',
      'waktu bayar perangkat masa depan ditolak',
      v_error,
      CASE
        WHEN lower(v_error) LIKE '%masa depan%' THEN '✅ PASS'
        ELSE '❌ FAIL'
      END
    );
  END;

  -- Antrean dapat baru tersambung setelah shift pengganti ikut ditutup. Server
  -- harus memakai shift yang mencakup waktu transaksi, bukan hanya shift yang
  -- masih terbuka pada saat sinkronisasi.
  UPDATE public.shifts
  SET end_time = now() - interval '15 minutes'
  WHERE id = v_active_shift;

  PERFORM public.create_pos_order(
    p_outlet_id => v_outlet,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1,
      'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_user,
    p_shift_id => v_old_shift,
    p_order_id => v_delayed_order,
    p_created_at => v_tx_time,
    p_local_receipt_no => 'QA-RECOVERY-DELAYED'
  );

  SELECT shift_id, original_shift_id, total_amount
  INTO v_saved_shift, v_original_shift, v_order_total
  FROM public.orders
  WHERE id = v_delayed_order;

  INSERT INTO _offline_shift_results VALUES (
    'SHIFT-RECOVERY-05',
    'shift pengganti yang sudah tutup tetap cocok berdasarkan waktu transaksi',
    format('shift=%s original=%s', v_saved_shift, v_original_shift),
    CASE
      WHEN v_saved_shift = v_active_shift AND v_original_shift = v_old_shift
      THEN '✅ PASS'
      ELSE '❌ FAIL'
    END
  );

  v_result := public.record_pos_payment_with_context(
    p_order_id => v_delayed_order,
    p_outlet_id => v_outlet,
    p_shift_id => v_old_shift,
    p_force_order_shift => true,
    p_method => 'qris'::public.payment_method,
    p_amount => v_order_total,
    p_idempotency_key => 'qa-recovery-payment-delayed',
    p_finalize => true,
    p_paid_at => v_tx_time
  );

  SELECT shift_id INTO v_payment_shift
  FROM public.payments
  WHERE order_id = v_delayed_order
  ORDER BY paid_at DESC
  LIMIT 1;

  INSERT INTO _offline_shift_results VALUES (
    'SHIFT-RECOVERY-06',
    'pembayaran tertunda masuk ke shift yang mencakup waktu aslinya',
    format('payment_shift=%s status=%s', v_payment_shift, v_result->>'status'),
    CASE
      WHEN v_payment_shift = v_active_shift AND v_result->>'status' = 'paid'
      THEN '✅ PASS'
      ELSE '❌ FAIL'
    END
  );

  -- Transaksi yang benar-benar terjadi sebelum till lama ditutup tidak boleh
  -- dipindah ke shift baru.
  PERFORM public.create_pos_order(
    p_outlet_id => v_outlet,
    p_order_type => 'dine_in'::public.order_type,
    p_status => 'confirmed'::public.order_status,
    p_items => jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1,
      'unit_price', 10000,
      'extras', '[]'::jsonb
    )),
    p_created_by => v_user,
    p_shift_id => v_old_shift,
    p_order_id => v_historical_order,
    p_created_at => v_old_end - interval '5 minutes',
    p_local_receipt_no => 'QA-RECOVERY-002'
  );

  SELECT shift_id, original_shift_id
  INTO v_saved_shift, v_original_shift
  FROM public.orders
  WHERE id = v_historical_order;

  INSERT INTO _offline_shift_results VALUES (
    'SHIFT-RECOVERY-03',
    'transaksi historis tetap pada shift asal',
    format('shift=%s original=%s', v_saved_shift, v_original_shift),
    CASE
      WHEN v_saved_shift = v_old_shift AND v_original_shift IS NULL
      THEN '✅ PASS'
      ELSE '❌ FAIL'
    END
  );

  -- Jam perangkat yang terlalu jauh ke depan harus ditolak secara eksplisit.
  BEGIN
    PERFORM public.create_pos_order(
      p_outlet_id => v_outlet,
      p_order_type => 'dine_in'::public.order_type,
      p_status => 'confirmed'::public.order_status,
      p_items => jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu,
        'quantity', 1,
        'unit_price', 10000,
        'extras', '[]'::jsonb
      )),
      p_created_by => v_user,
      p_shift_id => v_active_shift,
      p_order_id => gen_random_uuid(),
      p_created_at => now() + interval '1 hour',
      p_local_receipt_no => 'QA-RECOVERY-FUTURE'
    );
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-04',
      'waktu perangkat masa depan ditolak',
      'tidak ditolak',
      '❌ FAIL'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    INSERT INTO _offline_shift_results VALUES (
      'SHIFT-RECOVERY-04',
      'waktu perangkat masa depan ditolak',
      v_error,
      CASE
        WHEN lower(v_error) LIKE '%masa depan%' THEN '✅ PASS'
        ELSE '❌ FAIL'
      END
    );
  END;
END;
$$;

SELECT CASE
  WHEN count(*) FILTER (WHERE status = '❌ FAIL') = 0
  THEN '✅ ALL OFFLINE SHIFT RECOVERY TESTS PASSED'
  ELSE '❌ OFFLINE SHIFT RECOVERY TEST FAILED'
END AS summary
FROM _offline_shift_results;
SELECT * FROM _offline_shift_results ORDER BY test_case;

ROLLBACK;

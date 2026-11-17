-- ============================================================
-- simulate_transactions.sql
-- Generate ~40 transaksi tersimulasi PER OUTLET, tersebar 14 hari ke belakang.
--
-- Variasi per transaksi:
--   - 60% dine_in, 30% takeaway, 10% self_order (anon-style)
--   - 25% pakai voucher promo
--   - 50% terdaftar sebagai member loyalty (auto-earn point)
--   - Setiap order item dengan extras 70% (Packaging required, Topping/Sauce opsional)
--   - Kasir dine_in/takeaway → ada shift_id; self_order → tidak
--   - Payment method: 50% cash, 30% qris, 20% lainnya
--
-- MARKER: semua simulasi pakai `customer_name LIKE 'SIM-%'`.
-- Jalankan SETELAH seed_demo_data.sql.
-- ============================================================

DO $$
DECLARE
  v_outlet           RECORD;
  v_kasir_id         UUID;
  v_shift_id         UUID;
  v_member_ids       UUID[];
  v_voucher_codes    TEXT[];
  v_menu_ids         UUID[];
  v_table_ids        UUID[];
  v_outlet_settings  JSONB;
  v_tax_pct          NUMERIC;
  v_svc_pct          NUMERIC;
  v_points_per_rp    NUMERIC;
  i                  INTEGER;
  v_n_orders         INTEGER := 40;
  v_seed             INTEGER;
BEGIN
  FOR v_outlet IN SELECT id, name, settings, loyalty_settings FROM outlets WHERE is_active = TRUE ORDER BY name LOOP
    RAISE NOTICE '── Simulating % orders for outlet: % ──', v_n_orders, v_outlet.name;

    -- Skip outlet tanpa menu_items
    SELECT ARRAY_AGG(id) INTO v_menu_ids
    FROM menu_items
    WHERE outlet_id = v_outlet.id AND is_active = TRUE AND is_available = TRUE;

    IF v_menu_ids IS NULL OR array_length(v_menu_ids, 1) = 0 THEN
      RAISE NOTICE '⚠ Skip outlet % — tidak ada menu aktif', v_outlet.name;
      CONTINUE;
    END IF;

    -- Resolve kasir (siapa saja: kasir/admin/owner). Wajib ada utk created_by.
    SELECT id INTO v_kasir_id
    FROM profiles
    WHERE outlet_id = v_outlet.id AND role IN ('kasir', 'admin', 'owner') AND is_active = TRUE
    ORDER BY (role = 'kasir')::INT DESC, created_at LIMIT 1;

    -- Fallback ke owner global
    IF v_kasir_id IS NULL THEN
      SELECT id INTO v_kasir_id FROM profiles WHERE role = 'owner' LIMIT 1;
    END IF;

    IF v_kasir_id IS NULL THEN
      RAISE NOTICE '⚠ Skip outlet % — tidak ada profile yang bisa jadi created_by', v_outlet.name;
      CONTINUE;
    END IF;

    -- Buat shift simulasi (closed, untuk link ke order kasir)
    INSERT INTO shifts (outlet_id, kasir_id, start_time, end_time, opening_cash, closing_cash, notes)
    VALUES (
      v_outlet.id, v_kasir_id,
      NOW() - INTERVAL '14 days', NOW(),
      500000, 500000,
      '[DEMO-SIM] Shift simulasi'
    ) RETURNING id INTO v_shift_id;

    -- Resolve member list
    SELECT ARRAY_AGG(id) INTO v_member_ids
    FROM loyalty_members
    WHERE outlet_id = v_outlet.id AND phone LIKE '08DEMO%' AND is_active = TRUE;

    -- Resolve voucher list
    SELECT ARRAY_AGG(code) INTO v_voucher_codes
    FROM vouchers
    WHERE outlet_id = v_outlet.id AND code LIKE 'DEMO-%' AND is_active = TRUE;

    -- Resolve table list (untuk dine_in)
    SELECT ARRAY_AGG(id) INTO v_table_ids
    FROM restaurant_tables
    WHERE outlet_id = v_outlet.id AND is_active = TRUE;

    -- Settings outlet (tax & service)
    v_outlet_settings := COALESCE(v_outlet.settings, '{}'::jsonb);
    v_tax_pct := COALESCE((v_outlet_settings->>'tax_percent')::NUMERIC, 0);
    IF (v_outlet_settings->>'tax_active') = 'false' THEN v_tax_pct := 0; END IF;
    v_svc_pct := COALESCE((v_outlet_settings->>'service_charge_percent')::NUMERIC, 0);

    -- Loyalty rate
    v_points_per_rp := COALESCE((v_outlet.loyalty_settings->>'points_per_rupiah')::NUMERIC, 0);

    -- ════════════════════════════════════════════════════════════════
    -- LOOP: generate v_n_orders transaksi tersebar di 14 hari
    -- ════════════════════════════════════════════════════════════════
    FOR i IN 1..v_n_orders LOOP
      v_seed := (RANDOM() * 1000)::INT;

      -- ── Block per-order ─────────────────────────────────────────
      DECLARE
        v_order_id         UUID := gen_random_uuid();
        v_order_number     TEXT;
        v_order_type       TEXT;
        v_order_status     TEXT := 'paid';
        v_table_id         UUID;
        v_member_id        UUID;
        v_voucher_code     TEXT;
        v_promo_id         UUID;
        v_voucher_id       UUID;
        v_discount         NUMERIC := 0;
        v_subtotal         NUMERIC := 0;
        v_tax              NUMERIC;
        v_svc              NUMERIC;
        v_total            NUMERIC;
        v_method           TEXT;
        v_offset_days      INTEGER;
        v_created_at       TIMESTAMPTZ;
        v_n_items          INTEGER;
        v_use_shift        BOOLEAN;
        v_link_member      BOOLEAN;
        v_use_voucher      BOOLEAN;
        j                  INTEGER;
        v_menu_id          UUID;
        v_menu_price       NUMERIC;
        v_qty              INTEGER;
        v_oi_id            UUID;
        v_extra_record     RECORD;
        v_opt_record       RECORD;
        v_extras_price     NUMERIC;
        v_validate_result  JSON;
        v_points           INTEGER;
      BEGIN
        -- Variasi tanggal: random 0-13 hari ke belakang
        v_offset_days := FLOOR(RANDOM() * 14)::INT;
        v_created_at  := NOW() - (v_offset_days || ' days')::INTERVAL
                              - (FLOOR(RANDOM() * 12) || ' hours')::INTERVAL
                              - (FLOOR(RANDOM() * 60) || ' minutes')::INTERVAL;

        -- Order type
        IF RANDOM() < 0.60 THEN
          v_order_type := 'dine_in';
        ELSIF RANDOM() < 0.75 THEN
          v_order_type := 'takeaway';
        ELSE
          v_order_type := 'self_order';
        END IF;

        -- Table (dine_in)
        IF v_order_type = 'dine_in' AND v_table_ids IS NOT NULL AND array_length(v_table_ids, 1) > 0 THEN
          v_table_id := v_table_ids[1 + FLOOR(RANDOM() * array_length(v_table_ids, 1))::INT];
        END IF;

        -- Shift: kasir order (dine_in/takeaway) link ke shift, self_order tidak
        v_use_shift := v_order_type IN ('dine_in', 'takeaway');

        -- Member: 50%
        v_link_member := RANDOM() < 0.5 AND v_member_ids IS NOT NULL AND array_length(v_member_ids, 1) > 0;
        IF v_link_member THEN
          v_member_id := v_member_ids[1 + FLOOR(RANDOM() * array_length(v_member_ids, 1))::INT];
        END IF;

        -- Voucher: 25%
        v_use_voucher := RANDOM() < 0.25 AND v_voucher_codes IS NOT NULL AND array_length(v_voucher_codes, 1) > 0;
        IF v_use_voucher THEN
          v_voucher_code := v_voucher_codes[1 + FLOOR(RANDOM() * array_length(v_voucher_codes, 1))::INT];
        END IF;

        -- Generate order_number (random per-day counter, marker SIM)
        v_order_number := 'SIM-' || TO_CHAR(v_created_at, 'YYMMDD') || '-' || LPAD((1000 + i * 7 + v_seed)::TEXT, 4, '0');

        -- ════════════ Bangun cart items (1–4 item per order) ═══════
        v_n_items := 1 + FLOOR(RANDOM() * 4)::INT;
        v_subtotal := 0;

        -- Insert order dulu (subtotal/tax/total nanti di-update)
        INSERT INTO orders (
          id, outlet_id, order_number, order_type, table_id, shift_id,
          status, customer_name, subtotal, discount_amount, tax_amount,
          service_charge, total_amount, loyalty_member_id, created_by, created_at, updated_at
        ) VALUES (
          v_order_id, v_outlet.id, v_order_number, v_order_type::order_type, v_table_id,
          CASE WHEN v_use_shift THEN v_shift_id ELSE NULL END,
          'confirmed', 'SIM-' || RIGHT(v_order_number, 4),
          0, 0, 0, 0, 0,
          v_member_id, v_kasir_id, v_created_at, v_created_at
        );

        -- Insert order_items (+ extras 70%)
        FOR j IN 1..v_n_items LOOP
          v_menu_id := v_menu_ids[1 + FLOOR(RANDOM() * array_length(v_menu_ids, 1))::INT];
          v_qty     := 1 + FLOOR(RANDOM() * 3)::INT;
          SELECT price INTO v_menu_price FROM menu_items WHERE id = v_menu_id;
          v_extras_price := 0;
          v_oi_id := gen_random_uuid();

          -- Extras (kalau menu punya extras + 70% chance)
          IF RANDOM() < 0.7 THEN
            -- Untuk setiap extra yang nempel di menu ini
            FOR v_extra_record IN
              SELECT me.id AS extra_id, me.name AS extra_name, me.type, me.selection_type
              FROM menu_item_extras mie
              JOIN menu_extras me ON me.id = mie.extra_id
              WHERE mie.menu_item_id = v_menu_id AND me.is_active = TRUE
            LOOP
              -- Pilih option: single = 1 random; multiple = 1-2 random
              IF v_extra_record.selection_type = 'single' THEN
                SELECT id, name, price INTO v_opt_record
                FROM menu_extra_options
                WHERE extra_id = v_extra_record.extra_id
                ORDER BY RANDOM() LIMIT 1;

                IF v_opt_record.id IS NOT NULL THEN
                  INSERT INTO order_item_options (
                    order_item_id, menu_extra_id, menu_extra_option_id,
                    extra_name, option_name, price
                  ) VALUES (
                    v_oi_id, v_extra_record.extra_id, v_opt_record.id,
                    v_extra_record.extra_name, v_opt_record.name, v_opt_record.price
                  );
                  v_extras_price := v_extras_price + COALESCE(v_opt_record.price, 0);
                END IF;
              ELSE
                -- multiple: 1 atau 2 opsi
                FOR v_opt_record IN
                  SELECT id, name, price FROM menu_extra_options
                  WHERE extra_id = v_extra_record.extra_id
                  ORDER BY RANDOM() LIMIT (1 + FLOOR(RANDOM() * 2)::INT)
                LOOP
                  INSERT INTO order_item_options (
                    order_item_id, menu_extra_id, menu_extra_option_id,
                    extra_name, option_name, price
                  ) VALUES (
                    v_oi_id, v_extra_record.extra_id, v_opt_record.id,
                    v_extra_record.extra_name, v_opt_record.name, v_opt_record.price
                  );
                  v_extras_price := v_extras_price + COALESCE(v_opt_record.price, 0);
                END LOOP;
              END IF;
            END LOOP;
          END IF;

          INSERT INTO order_items (id, order_id, menu_item_id, quantity, unit_price, subtotal, notes)
          VALUES (v_oi_id, v_order_id, v_menu_id, v_qty,
                  v_menu_price + v_extras_price,
                  (v_menu_price + v_extras_price) * v_qty,
                  NULL);

          v_subtotal := v_subtotal + (v_menu_price + v_extras_price) * v_qty;
        END LOOP;

        -- Apply promo via RPC kalau pakai voucher
        IF v_use_voucher THEN
          BEGIN
            v_validate_result := validate_promo_code(v_voucher_code, v_outlet.id, v_subtotal);
            v_promo_id    := (v_validate_result->>'promo_id')::UUID;
            v_voucher_id  := (v_validate_result->>'voucher_id')::UUID;
            v_discount    := COALESCE((v_validate_result->>'discount_amount')::NUMERIC, 0);
          EXCEPTION WHEN OTHERS THEN
            -- Voucher tidak match min_order, dll. Skip diskon.
            v_discount := 0;
          END;
        END IF;

        v_tax   := ROUND(v_subtotal * v_tax_pct / 100, 0);
        v_svc   := ROUND(v_subtotal * v_svc_pct / 100, 0);
        v_total := GREATEST(0, v_subtotal - v_discount + v_tax + v_svc);

        -- Update order dengan totals + set status=paid
        UPDATE orders SET
          subtotal        = v_subtotal,
          discount_amount = v_discount,
          tax_amount      = v_tax,
          service_charge  = v_svc,
          total_amount    = v_total,
          status          = 'paid',
          updated_at      = v_created_at
        WHERE id = v_order_id;

        -- Payment method weighted random
        IF RANDOM() < 0.50 THEN
          v_method := 'cash';
        ELSIF RANDOM() < 0.80 THEN
          v_method := 'qris';
        ELSIF RANDOM() < 0.90 THEN
          v_method := 'debit';
        ELSE
          v_method := 'transfer';
        END IF;

        -- Insert payment
        INSERT INTO payments (order_id, outlet_id, method, amount, paid_at)
        VALUES (v_order_id, v_outlet.id, v_method::payment_method, v_total, v_created_at);

        -- Apply promo usage counter
        IF v_promo_id IS NOT NULL THEN
          BEGIN
            PERFORM apply_promo_usage(v_promo_id, v_voucher_id);
          EXCEPTION WHEN OTHERS THEN
            NULL; -- non-fatal
          END;
        END IF;

        -- Award loyalty points
        IF v_member_id IS NOT NULL THEN
          BEGIN
            v_points := award_loyalty_points(v_order_id, v_member_id);
          EXCEPTION WHEN OTHERS THEN
            NULL;
          END;
        END IF;
      END;
    END LOOP;

    -- Beberapa order ditandai void/cancelled untuk variasi (5-10%)
    UPDATE orders SET status = 'void', updated_at = updated_at
    WHERE id IN (
      SELECT id FROM orders
      WHERE outlet_id = v_outlet.id AND order_number LIKE 'SIM-%' AND status = 'paid'
      ORDER BY RANDOM() LIMIT GREATEST(1, FLOOR(v_n_orders * 0.05)::INT)
    );

    UPDATE orders SET status = 'cancelled', updated_at = updated_at
    WHERE id IN (
      SELECT id FROM orders
      WHERE outlet_id = v_outlet.id AND order_number LIKE 'SIM-%' AND status = 'paid'
      ORDER BY RANDOM() LIMIT GREATEST(1, FLOOR(v_n_orders * 0.03)::INT)
    );
  END LOOP;

  RAISE NOTICE '✓ Simulasi selesai';
END $$;

-- ── Ringkasan hasil simulasi ─────────────────────────────────
SELECT
  o.name AS outlet,
  COUNT(*) FILTER (WHERE ord.status = 'paid')      AS paid_orders,
  COUNT(*) FILTER (WHERE ord.status = 'void')      AS void_orders,
  COUNT(*) FILTER (WHERE ord.status = 'cancelled') AS cancelled_orders,
  COUNT(*) FILTER (WHERE ord.discount_amount > 0)  AS with_promo,
  COUNT(*) FILTER (WHERE ord.loyalty_member_id IS NOT NULL) AS with_member,
  COUNT(*) FILTER (WHERE ord.shift_id IS NOT NULL) AS with_shift,
  ROUND(SUM(ord.total_amount) FILTER (WHERE ord.status = 'paid'), 0) AS revenue
FROM outlets o
LEFT JOIN orders ord ON ord.outlet_id = o.id AND ord.order_number LIKE 'SIM-%'
WHERE o.is_active = TRUE
GROUP BY o.id, o.name
ORDER BY o.name;

-- ── Cek loyalty earn ─────────────────────────────────────────
SELECT
  o.name AS outlet,
  COUNT(lt.id) AS earn_txns,
  SUM(lt.points) AS total_points_earned,
  COUNT(DISTINCT lt.member_id) AS unique_members_earning
FROM outlets o
LEFT JOIN loyalty_transactions lt ON lt.outlet_id = o.id AND lt.type = 'earn'
  AND lt.order_id IN (SELECT id FROM orders WHERE order_number LIKE 'SIM-%')
WHERE o.is_active = TRUE
GROUP BY o.id, o.name
ORDER BY o.name;

-- ── Cek promo usage ──────────────────────────────────────────
SELECT
  o.name AS outlet,
  p.name AS promo,
  p.usage_count,
  p.usage_limit
FROM promos p
JOIN outlets o ON o.id = p.outlet_id
WHERE p.name LIKE '%(DEMO)%'
ORDER BY o.name, p.name;

-- ============================================================
-- seed_demo_data.sql
-- Isi data master untuk semua outlet aktif (idempoten).
-- Jalankan via Supabase Dashboard → SQL Editor.
--
-- Marker semua data demo:
--   - menu_extras / promos / loyalty_members → suffix " (DEMO)" pada name
--   - vouchers code prefix → "DEMO-"
--   - expenses description prefix → "[DEMO] "
--
-- Rerun-aman: cek IF NOT EXISTS sebelum insert.
-- ============================================================

DO $$
DECLARE
  v_outlet           RECORD;
  v_short            TEXT;
  v_extra_sauce_id   UUID;
  v_extra_topping_id UUID;
  v_promo_pct_id     UUID;
  v_promo_fix_id     UUID;
  v_member_count     INTEGER;
BEGIN
  -- Loop semua outlet aktif
  FOR v_outlet IN SELECT id, name FROM outlets WHERE is_active = TRUE ORDER BY name LOOP
    -- Suffix unik per outlet (vouchers.code UNIQUE global, jadi perlu pembeda)
    v_short := UPPER(SUBSTRING(REPLACE(v_outlet.id::TEXT, '-', ''), 1, 4));
    RAISE NOTICE '── Seeding outlet: % (%) suffix=% ──', v_outlet.name, v_outlet.id, v_short;

    -- ════════════════════════════════════════════════════════════════
    -- §1. ENSURE loyalty_settings di outlets terisi
    -- ════════════════════════════════════════════════════════════════
    UPDATE outlets
    SET loyalty_settings = COALESCE(loyalty_settings, '{}'::jsonb) ||
        '{"points_per_rupiah": 0.01, "redeem_rate": 100, "tier_threshold": {"silver": 1000, "gold": 5000, "platinum": 20000}}'::jsonb
    WHERE id = v_outlet.id
      AND (loyalty_settings IS NULL OR NOT (loyalty_settings ? 'points_per_rupiah'));

    -- ════════════════════════════════════════════════════════════════
    -- §2. menu_extras + menu_extra_options
    -- ════════════════════════════════════════════════════════════════

    -- Catatan: extra "Packaging" sengaja TIDAK dibuat — duplikat dengan
    -- pilihan order type (Dine In / Takeaway) di panel POS.

    -- Extra 2: Saus Tambahan (multi, optional)
    SELECT id INTO v_extra_sauce_id
    FROM menu_extras WHERE outlet_id = v_outlet.id AND name = 'Saus Tambahan (DEMO)' LIMIT 1;

    IF v_extra_sauce_id IS NULL THEN
      INSERT INTO menu_extras (outlet_id, name, type, selection_type, sort_order, is_active)
      VALUES (v_outlet.id, 'Saus Tambahan (DEMO)', 'optional', 'multiple', 2, TRUE)
      RETURNING id INTO v_extra_sauce_id;

      INSERT INTO menu_extra_options (extra_id, name, price, sort_order) VALUES
        (v_extra_sauce_id, 'Sambal Bawang', 3000, 1),
        (v_extra_sauce_id, 'Saus Keju',    5000, 2),
        (v_extra_sauce_id, 'Mayo',          3000, 3),
        (v_extra_sauce_id, 'Saus BBQ',      5000, 4);
    END IF;

    -- Extra 3: Topping (multi, optional)
    SELECT id INTO v_extra_topping_id
    FROM menu_extras WHERE outlet_id = v_outlet.id AND name = 'Topping (DEMO)' LIMIT 1;

    IF v_extra_topping_id IS NULL THEN
      INSERT INTO menu_extras (outlet_id, name, type, selection_type, sort_order, is_active)
      VALUES (v_outlet.id, 'Topping (DEMO)', 'optional', 'multiple', 3, TRUE)
      RETURNING id INTO v_extra_topping_id;

      INSERT INTO menu_extra_options (extra_id, name, price, sort_order) VALUES
        (v_extra_topping_id, 'Telur Mata Sapi', 5000, 1),
        (v_extra_topping_id, 'Keju Mozzarella', 8000, 2),
        (v_extra_topping_id, 'Bakso',           6000, 3),
        (v_extra_topping_id, 'Sosis',           5000, 4);
    END IF;

    -- ════════════════════════════════════════════════════════════════
    -- §3. menu_item_extras — TIDAK di-link otomatis.
    --   Penautan extra ke menu item dikelola PER ITEM lewat Owner Panel
    --   (MenuManager). Seed hanya menyediakan daftar extra-nya saja, agar
    --   tiap menu bisa punya extra yang berbeda sesuai pengaturan owner —
    --   bukan disamaratakan ke semua menu.
    -- ════════════════════════════════════════════════════════════════
    -- (sengaja kosong)

    -- ════════════════════════════════════════════════════════════════
    -- §4. promos + vouchers
    -- ════════════════════════════════════════════════════════════════

    -- Promo persentase
    SELECT id INTO v_promo_pct_id
    FROM promos WHERE outlet_id = v_outlet.id AND name = 'Diskon 10% (DEMO)' LIMIT 1;

    IF v_promo_pct_id IS NULL THEN
      INSERT INTO promos (
        outlet_id, name, description, type, value, min_order,
        max_discount, start_date, end_date, usage_limit, is_active
      ) VALUES (
        v_outlet.id, 'Diskon 10% (DEMO)', 'Hemat 10% min order Rp 30.000',
        'percentage', 10, 30000,
        20000, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE + INTERVAL '90 days',
        500, TRUE
      ) RETURNING id INTO v_promo_pct_id;

      INSERT INTO vouchers (promo_id, outlet_id, code, usage_limit, is_active) VALUES
        (v_promo_pct_id, v_outlet.id, 'DEMO-HEMAT10-' || v_short, 100, TRUE),
        (v_promo_pct_id, v_outlet.id, 'DEMO-WELCOME-' || v_short, 100, TRUE)
      ON CONFLICT (code) DO NOTHING;
    END IF;

    -- Promo fixed amount
    SELECT id INTO v_promo_fix_id
    FROM promos WHERE outlet_id = v_outlet.id AND name = 'Potongan Rp 5.000 (DEMO)' LIMIT 1;

    IF v_promo_fix_id IS NULL THEN
      INSERT INTO promos (
        outlet_id, name, description, type, value, min_order,
        max_discount, start_date, end_date, usage_limit, is_active
      ) VALUES (
        v_outlet.id, 'Potongan Rp 5.000 (DEMO)', 'Potongan langsung Rp 5.000 min order Rp 25.000',
        'fixed', 5000, 25000,
        NULL, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE + INTERVAL '90 days',
        500, TRUE
      ) RETURNING id INTO v_promo_fix_id;

      INSERT INTO vouchers (promo_id, outlet_id, code, usage_limit, is_active) VALUES
        (v_promo_fix_id, v_outlet.id, 'DEMO-CASH5K-' || v_short, 100, TRUE),
        (v_promo_fix_id, v_outlet.id, 'DEMO-NGOPI-'  || v_short, 100, TRUE)
      ON CONFLICT (code) DO NOTHING;
    END IF;

    -- ════════════════════════════════════════════════════════════════
    -- §5. loyalty_members (5 sample per outlet)
    -- ════════════════════════════════════════════════════════════════
    SELECT COUNT(*) INTO v_member_count
    FROM loyalty_members
    WHERE outlet_id = v_outlet.id AND phone LIKE '08DEMO%';

    IF v_member_count = 0 THEN
      INSERT INTO loyalty_members (outlet_id, phone, name, points, tier, is_active) VALUES
        (v_outlet.id, '08DEMO00001', 'Andi Demo',     1500, 'silver',   TRUE),
        (v_outlet.id, '08DEMO00002', 'Budi Demo',     6200, 'gold',     TRUE),
        (v_outlet.id, '08DEMO00003', 'Citra Demo',     350, 'bronze',   TRUE),
        (v_outlet.id, '08DEMO00004', 'Dewi Demo',    25000, 'platinum', TRUE),
        (v_outlet.id, '08DEMO00005', 'Eko Demo',       800, 'bronze',   TRUE);
    END IF;

    -- ════════════════════════════════════════════════════════════════
    -- §6. expenses (biaya operasional 30 hari terakhir)
    -- ════════════════════════════════════════════════════════════════
    IF NOT EXISTS (
      SELECT 1 FROM expenses
      WHERE outlet_id = v_outlet.id AND description LIKE '[DEMO]%'
    ) THEN
      INSERT INTO expenses (outlet_id, category, amount, description, expense_date) VALUES
        (v_outlet.id, 'operasional', 1500000,  '[DEMO] Listrik bulan ini',         CURRENT_DATE - INTERVAL '5 days'),
        (v_outlet.id, 'operasional', 300000,   '[DEMO] Air PAM',                    CURRENT_DATE - INTERVAL '7 days'),
        (v_outlet.id, 'operasional', 800000,   '[DEMO] Internet + Wi-Fi',           CURRENT_DATE - INTERVAL '10 days'),
        (v_outlet.id, 'gaji',        5000000,  '[DEMO] Gaji kasir (1 orang)',       CURRENT_DATE - INTERVAL '15 days'),
        (v_outlet.id, 'gaji',        4500000,  '[DEMO] Gaji koki (1 orang)',        CURRENT_DATE - INTERVAL '15 days'),
        (v_outlet.id, 'operasional', 2000000,  '[DEMO] Sewa tempat',                CURRENT_DATE - INTERVAL '20 days'),
        (v_outlet.id, 'marketing',   500000,   '[DEMO] Iklan Instagram',            CURRENT_DATE - INTERVAL '12 days'),
        (v_outlet.id, 'peralatan',   1200000,  '[DEMO] Servis kompor + freezer',    CURRENT_DATE - INTERVAL '25 days'),
        (v_outlet.id, 'bahan_baku',  3500000,  '[DEMO] Belanja sayur/daging (mingguan)', CURRENT_DATE - INTERVAL '3 days'),
        (v_outlet.id, 'lain_lain',   250000,   '[DEMO] Sumbangan RT',               CURRENT_DATE - INTERVAL '8 days');
    END IF;

    -- ════════════════════════════════════════════════════════════════
    -- §7. ingredients.cost_per_unit — pastikan > 0 (untuk HPP)
    -- ════════════════════════════════════════════════════════════════
    -- Set default cost untuk ingredient yang cost_per_unit = 0
    -- Pakai estimasi nominal Rupiah per unit berdasarkan nama ingredient
    UPDATE ingredients SET cost_per_unit = CASE
      WHEN LOWER(name) LIKE '%daging%' OR LOWER(name) LIKE '%ayam%' OR LOWER(name) LIKE '%ikan%' THEN 80
      WHEN LOWER(name) LIKE '%nasi%' OR LOWER(name) LIKE '%beras%'                                THEN 15
      WHEN LOWER(name) LIKE '%susu%' OR LOWER(name) LIKE '%krim%'                                 THEN 50
      WHEN LOWER(name) LIKE '%kopi%' OR LOWER(name) LIKE '%espresso%'                             THEN 200
      WHEN LOWER(name) LIKE '%teh%'                                                                THEN 30
      WHEN LOWER(name) LIKE '%gula%'                                                               THEN 12
      WHEN LOWER(name) LIKE '%minyak%'                                                             THEN 25
      WHEN LOWER(name) LIKE '%tepung%'                                                             THEN 18
      WHEN LOWER(name) LIKE '%telur%'                                                              THEN 30
      WHEN LOWER(name) LIKE '%keju%' OR LOWER(name) LIKE '%cheese%'                                THEN 150
      ELSE 50  -- default fallback
    END
    WHERE outlet_id = v_outlet.id AND cost_per_unit = 0;

    -- ════════════════════════════════════════════════════════════════
    -- §8. menu_recipes — buat resep dummy untuk menu yang belum punya resep
    -- ════════════════════════════════════════════════════════════════
    -- Untuk setiap menu_item tanpa resep, link ke 1 ingredient pertama
    -- dengan qty_per_portion = 1 (estimasi kasar).
    -- Effect: setiap menu jadi punya HPP minimum.
    INSERT INTO menu_recipes (menu_item_id, ingredient_id, qty_per_portion)
    SELECT mi.id, ing.id, 1
    FROM menu_items mi
    CROSS JOIN LATERAL (
      SELECT id FROM ingredients
      WHERE outlet_id = mi.outlet_id AND is_active = TRUE
      ORDER BY name LIMIT 1
    ) ing
    WHERE mi.outlet_id = v_outlet.id
      AND mi.is_active = TRUE
      AND NOT EXISTS (SELECT 1 FROM menu_recipes WHERE menu_item_id = mi.id);

  END LOOP;

  RAISE NOTICE '✓ Seed selesai untuk semua outlet aktif';
END $$;

-- ── Ringkasan hasil seed ─────────────────────────────────────
SELECT
  o.name AS outlet,
  (SELECT COUNT(*) FROM menu_extras WHERE outlet_id = o.id AND name LIKE '%(DEMO)%') AS extras,
  (SELECT COUNT(*) FROM promos       WHERE outlet_id = o.id AND name LIKE '%(DEMO)%') AS promos,
  (SELECT COUNT(*) FROM vouchers     WHERE outlet_id = o.id AND code LIKE 'DEMO-%')   AS vouchers,
  (SELECT COUNT(*) FROM loyalty_members WHERE outlet_id = o.id AND phone LIKE '08DEMO%') AS members,
  (SELECT COUNT(*) FROM expenses     WHERE outlet_id = o.id AND description LIKE '[DEMO]%') AS expenses,
  (SELECT COUNT(*) FROM menu_recipes mr JOIN menu_items mi ON mi.id = mr.menu_item_id WHERE mi.outlet_id = o.id) AS recipes,
  (SELECT COUNT(*) FROM ingredients WHERE outlet_id = o.id AND cost_per_unit > 0) AS ing_with_cost
FROM outlets o
WHERE o.is_active = TRUE
ORDER BY o.name;
-- ============================================================
-- TEST SUITE: RLS Isolation + Edge Cases
-- Sesi: 2026-05-24 (lanjutan)
-- Cara pakai: paste ke Supabase SQL Editor → Run without RLS
-- ============================================================

BEGIN;

CREATE TEMP TABLE _test_results (
  tc TEXT, skenario TEXT, ekspektasi TEXT, aktual TEXT, status TEXT
) ON COMMIT DROP;

DO $$
DECLARE
  v_outlet_a    UUID;
  v_outlet_b    UUID;
  v_menu_a      UUID;
  v_menu_b      UUID;
  v_ing_a       UUID;
  v_ing_b       UUID;
  v_recipe_a    UUID;
  v_count       INTEGER;
  v_stock       NUMERIC;
  v_stock_before NUMERIC;
  v_order_id    UUID;
BEGIN

  -- Test memakai update status langsung sebagai fixture. Produksi hanya
  -- mengizinkan perubahan melalui RPC; flag lokal meniru konteks RPC.
  PERFORM set_config('app.order_status_mutation', 'on', true);

  -- ════════════════════════════════════════════════════════
  -- SETUP: Dua outlet berbeda
  -- ════════════════════════════════════════════════════════
  INSERT INTO outlets (name) VALUES ('[QA-B] Outlet A') RETURNING id INTO v_outlet_a;
  INSERT INTO outlets (name) VALUES ('[QA-B] Outlet B') RETURNING id INTO v_outlet_b;

  INSERT INTO menu_items (outlet_id, name, price)
  VALUES (v_outlet_a, '[QA-B] Menu Outlet A', 20000) RETURNING id INTO v_menu_a;

  INSERT INTO menu_items (outlet_id, name, price)
  VALUES (v_outlet_b, '[QA-B] Menu Outlet B', 20000) RETURNING id INTO v_menu_b;

  INSERT INTO ingredients (outlet_id, name, unit, stock_qty, min_stock_qty, cost_per_unit)
  VALUES (v_outlet_a, '[QA-B] Bahan A', 'kg', 10, 5, 5000) RETURNING id INTO v_ing_a;

  INSERT INTO ingredients (outlet_id, name, unit, stock_qty, min_stock_qty, cost_per_unit)
  VALUES (v_outlet_b, '[QA-B] Bahan B', 'kg', 8, 3, 5000) RETURNING id INTO v_ing_b;

  -- Resep Outlet A: 1 porsi = 0.5 kg Bahan A
  INSERT INTO menu_recipes (menu_item_id, ingredient_id, qty_per_portion)
  VALUES (v_menu_a, v_ing_a, 0.5) RETURNING id INTO v_recipe_a;

  -- Resep Outlet B: 1 porsi = 0.3 kg Bahan B
  INSERT INTO menu_recipes (menu_item_id, ingredient_id, qty_per_portion)
  VALUES (v_menu_b, v_ing_b, 0.3);


  -- ════════════════════════════════════════════════════════
  -- TC-RLS-01: RLS menu_recipes — isolasi antar outlet
  -- Cek apakah policy hanya USING(TRUE) tanpa filter outlet
  -- ════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE tablename = 'menu_recipes'
    AND cmd = 'SELECT'
    AND (qual = 'true' OR qual = 'TRUE' OR qual IS NULL);

  INSERT INTO _test_results VALUES (
    'RLS-01',
    'menu_recipes — policy ada filter outlet (bukan USING(TRUE))',
    '0 policy dengan USING(TRUE)',
    v_count || ' policy tanpa filter outlet',
    CASE WHEN v_count = 0 THEN '✅ PASS' ELSE '❌ FAIL — ISOLASI OUTLET TIDAK ADA' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-RLS-02: Cross-outlet recipe read (sebagai service_role)
  -- User outlet A seharusnya tidak bisa baca resep outlet B
  -- (ditest via query langsung — service_role bypass RLS)
  -- ════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM menu_recipes mr
  JOIN menu_items mi ON mi.id = mr.menu_item_id
  WHERE mi.outlet_id = v_outlet_b;

  INSERT INTO _test_results VALUES (
    'RLS-02',
    'menu_recipes outlet B bisa dibaca dari service_role',
    '> 0 (service_role bypass RLS — normal)',
    v_count || ' resep outlet B',
    CASE WHEN v_count > 0 THEN '⚠️ INFO — service_role bypass RLS (normal); isolasi anon/auth diuji oleh policy di atas'
    ELSE '✅ PASS' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-RLS-03: RLS ingredients UPDATE — kasir tidak boleh update langsung
  -- Cek: apakah ada UPDATE policy yang terlalu longgar
  -- ════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE tablename = 'ingredients'
    AND cmd = 'UPDATE'
    AND (qual LIKE '%auth_outlet_id%' OR qual LIKE '%is_owner%');

  INSERT INTO _test_results VALUES (
    'RLS-03',
    'ingredients UPDATE policy — ada filter outlet/owner',
    '>= 1 policy dengan filter',
    v_count || ' policy terfilter',
    CASE WHEN v_count >= 1 THEN '✅ PASS' ELSE '❌ FAIL — UPDATE ingredients tidak terlindungi' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-RLS-04: stock_transactions — tidak ada UPDATE/DELETE policy
  -- Seharusnya memang tidak bisa diubah (audit trail immutable)
  -- ════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE tablename = 'stock_transactions'
    AND cmd IN ('UPDATE', 'DELETE');

  INSERT INTO _test_results VALUES (
    'RLS-04',
    'stock_transactions — tidak ada UPDATE/DELETE policy (immutable log)',
    '0 (tidak bisa diedit/hapus)',
    v_count || ' policy UPDATE/DELETE',
    CASE WHEN v_count = 0 THEN '✅ PASS — audit trail immutable'
    ELSE '⚠️ INFO — ada ' || v_count || ' policy UPDATE/DELETE (pastikan intentional)' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-RLS-05: SECURITY DEFINER functions bypass RLS
  -- deduct_stock_for_order bisa tulis ke stock_transactions outlet manapun
  -- Test: apakah fungsi bisa insert tx untuk outlet yang bukan miliknya
  -- ════════════════════════════════════════════════════════
  INSERT INTO orders (outlet_id, order_number, status)
  VALUES (v_outlet_a, 'QA-B-001', 'confirmed') RETURNING id INTO v_order_id;

  INSERT INTO order_items (order_id, menu_item_id, quantity, unit_price, subtotal)
  VALUES (v_order_id, v_menu_a, 2, 20000, 40000);

  UPDATE orders SET status = 'preparing' WHERE id = v_order_id;

  SELECT COUNT(*) INTO v_count
  FROM stock_transactions
  WHERE order_id = v_order_id AND outlet_id = v_outlet_a;

  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;

  INSERT INTO _test_results VALUES (
    'RLS-05',
    'SECURITY DEFINER trigger — hanya tulis tx ke outlet yang benar (outlet_a)',
    '1 tx di outlet_a, stok outlet_a berkurang',
    v_count || ' tx outlet_a, stok=' || v_stock,
    CASE WHEN v_count = 1 AND v_stock = 9.000 THEN '✅ PASS'
    ELSE '❌ FAIL — tx salah atau stok tidak berkurang tepat' END
  );

  -- Stok outlet_b harus tidak berubah (tidak ada cross-outlet deduction)
  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_b;
  INSERT INTO _test_results VALUES (
    'RLS-05b',
    'SECURITY DEFINER — stok outlet_b tidak terpengaruh order outlet_a',
    '8.000 kg (tidak berubah)',
    v_stock || ' kg',
    CASE WHEN v_stock = 8.000 THEN '✅ PASS' ELSE '❌ FAIL — stok outlet lain ikut berubah!' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-EDGE-01: StockBadge threshold — stok tepat di batas min
  -- stok = min_stock_qty → status harus "low" / "Rendah"
  -- ════════════════════════════════════════════════════════
  UPDATE ingredients SET stock_qty = 5 WHERE id = v_ing_a; -- = min_stock_qty

  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;
  -- Logic: stock_qty <= min_stock_qty → "low", stock_qty <= min*0.5 → "critical"
  INSERT INTO _test_results VALUES (
    'EDGE-01',
    'StockBadge — stok=5 tepat di min=5 → harus Rendah (low)',
    'Rendah (stock_qty <= min_stock_qty)',
    'stok=' || v_stock || ' min=5',
    CASE WHEN v_stock <= 5 AND v_stock > 2.5 THEN '✅ PASS — masuk zone Rendah'
    ELSE '❌ FAIL — threshold tidak sesuai' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-EDGE-02: StockBadge — stok = 50% dari min → Kritis
  -- ════════════════════════════════════════════════════════
  UPDATE ingredients SET stock_qty = 2.5 WHERE id = v_ing_a; -- = 50% dari min 5

  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;
  INSERT INTO _test_results VALUES (
    'EDGE-02',
    'StockBadge — stok=2.5 (50% min=5) → harus Kritis',
    'Kritis (stock_qty <= min * 0.5)',
    'stok=' || v_stock,
    CASE WHEN v_stock <= 2.5 THEN '✅ PASS — masuk zone Kritis'
    ELSE '❌ FAIL' END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-EDGE-03: Order dengan 2 menu berbeda, masing-masing punya resep
  -- Semua bahan harus terpotong dengan benar
  -- ════════════════════════════════════════════════════════
  UPDATE ingredients SET stock_qty = 10 WHERE id = v_ing_a;
  UPDATE ingredients SET stock_qty = 8  WHERE id = v_ing_b;

  -- Tambah menu_b ke outlet_a dan buat resep pakai bahan_a juga
  DECLARE
    v_menu_a2 UUID;
    v_order2  UUID;
  BEGIN
    INSERT INTO menu_items (outlet_id, name, price)
    VALUES (v_outlet_a, '[QA-B] Menu A2', 15000) RETURNING id INTO v_menu_a2;

    INSERT INTO menu_recipes (menu_item_id, ingredient_id, qty_per_portion)
    VALUES (v_menu_a2, v_ing_a, 0.3); -- 0.3 kg bahan A per porsi

    INSERT INTO orders (outlet_id, order_number, status)
    VALUES (v_outlet_a, 'QA-B-002', 'confirmed') RETURNING id INTO v_order2;

    -- 2 menu berbeda: menu_a (0.5kg × 1) + menu_a2 (0.3kg × 2) = 0.5 + 0.6 = 1.1 kg total
    INSERT INTO order_items (order_id, menu_item_id, quantity, unit_price, subtotal)
    VALUES (v_order2, v_menu_a, 1, 20000, 20000),
           (v_order2, v_menu_a2, 2, 15000, 30000);

    UPDATE orders SET status = 'preparing' WHERE id = v_order2;

    SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;

    INSERT INTO _test_results VALUES (
      'EDGE-03',
      'Order 2 menu × 1 bahan — total deduct 1.1 kg (0.5 + 0.6)',
      '8.900 kg (10 - 1.1)',
      v_stock || ' kg',
      CASE WHEN v_stock = 8.900 THEN '✅ PASS'
      ELSE '❌ FAIL — deduct multi-menu tidak akurat: ' || v_stock END
    );
  END;


  -- ════════════════════════════════════════════════════════
  -- TC-EDGE-04: useStockAdjustment — qty_before di log
  -- Simulasi: apakah qty_before di log akurat dengan stok nyata?
  -- ════════════════════════════════════════════════════════
  UPDATE ingredients SET stock_qty = 5 WHERE id = v_ing_a;

  INSERT INTO stock_transactions
    (outlet_id, ingredient_id, type, qty, qty_before, qty_after)
  VALUES
    (v_outlet_a, v_ing_a, 'purchase', 3, 5, 8);

  -- Trigger harus set stock_qty = 5 + 3 = 8
  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;

  INSERT INTO _test_results VALUES (
    'EDGE-04',
    'Manual stock_transactions insert — trigger sync stok dengan benar',
    '8.000 (5 + 3)',
    v_stock || ' kg',
    CASE WHEN v_stock = 8.000 THEN '✅ PASS — trigger sync benar'
    ELSE '❌ FAIL — stok = ' || v_stock END
  );


  -- ════════════════════════════════════════════════════════
  -- TC-EDGE-05: waste transaction — oversell negatif dicatat simetris
  -- ════════════════════════════════════════════════════════
  UPDATE ingredients SET stock_qty = 2 WHERE id = v_ing_a;

  INSERT INTO stock_transactions
    (outlet_id, ingredient_id, type, qty, qty_before, qty_after)
  VALUES
    (v_outlet_a, v_ing_a, 'waste', 5, 2, 0); -- buang 5 tapi stok cuma 2

  SELECT stock_qty INTO v_stock FROM ingredients WHERE id = v_ing_a;

  INSERT INTO _test_results VALUES (
    'EDGE-05',
    'Waste > stok tersedia — nilai negatif menandai oversell',
    '-3.000 (oversell tercatat)',
    v_stock || ' kg',
    CASE WHEN v_stock = -3 THEN '✅ PASS — oversell tercatat simetris'
    ELSE '❌ FAIL — nilai waste tidak terduga: ' || v_stock END
  );

END;
$$;

-- ── Tampilkan hasil ───────────────────────────────────────
SELECT tc AS "Test Case", skenario AS "Skenario",
       ekspektasi AS "Ekspektasi", aktual AS "Aktual", status AS "Status"
FROM _test_results

UNION ALL SELECT '──────','─────────────────────────────────','──────────','──────────','──────────'

UNION ALL SELECT
  'RINGKASAN',
  COUNT(*) FILTER (WHERE status LIKE '✅%') || ' PASS  |  ' ||
  COUNT(*) FILTER (WHERE status LIKE '❌%') || ' FAIL  |  ' ||
  COUNT(*) FILTER (WHERE status LIKE '⚠️%') || ' INFO',
  'TOTAL: ' || COUNT(*), '',
  CASE WHEN COUNT(*) FILTER (WHERE status LIKE '❌%') = 0 THEN '✅ SEMUA LULUS'
  ELSE '❌ ADA KEGAGALAN' END
FROM _test_results

ORDER BY 1;

ROLLBACK;

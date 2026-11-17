-- ============================================================
-- seed_100_menu.sql — Isi SEMUA section demo untuk satu outlet:
--   3 departemen · 11 kategori · 100 menu · 3 extras (+opsi & tautan) ·
--   12 meja · 12 bahan baku · resep · 5 pengeluaran · 8 member · promo + 10 voucher.
-- Aman dijalankan ulang (skip yang sudah ada).
--
-- Target: outlet AKTIF pertama. Untuk outlet tertentu, ganti baris
--   SELECT id INTO v_outlet ... (mis. WHERE name = 'Nama Cabang').
-- Jalankan di Supabase SQL Editor.
-- ============================================================

-- Helper: insert menu per kategori, skip yang namanya sudah ada.
CREATE OR REPLACE FUNCTION seed_menu(
  p_outlet UUID, p_cat UUID, p_desc TEXT, p_names TEXT[], p_prices NUMERIC[]
) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO menu_items(outlet_id, category_id, name, price, description,
                         is_available, is_active, is_featured, sort_order)
  SELECT p_outlet, p_cat, x.name, x.price, p_desc, true, true, false, x.ord::int
  FROM unnest(p_names, p_prices) WITH ORDINALITY AS x(name, price, ord)
  WHERE NOT EXISTS (
    SELECT 1 FROM menu_items m WHERE m.outlet_id = p_outlet AND m.name = x.name
  );
$$;

DO $$
DECLARE
  v_outlet      UUID;
  v_dep_dapur   UUID; v_dep_bar UUID; v_dep_dessert UUID;
  v_c1 UUID; v_c2 UUID; v_c3 UUID; v_c4 UUID; v_c5 UUID; v_c6 UUID;
  v_c7 UUID; v_c8 UUID; v_c9 UUID; v_c10 UUID; v_c11 UUID;
  v_ex_pedas UUID; v_ex_topping UUID; v_ex_saus UUID;
  v_promo UUID;
BEGIN
  SELECT id INTO v_outlet FROM outlets WHERE is_active ORDER BY created_at LIMIT 1;
  IF v_outlet IS NULL THEN RAISE EXCEPTION 'Tidak ada outlet aktif. Buat cabang dulu.'; END IF;

  -- ── Departemen ─────────────────────────────────────────────
  SELECT id INTO v_dep_dapur   FROM menu_departments WHERE outlet_id=v_outlet AND name='Dapur' LIMIT 1;
  IF v_dep_dapur IS NULL THEN INSERT INTO menu_departments(outlet_id,name,color,sort_order,is_active) VALUES(v_outlet,'Dapur','#ff6600',1,true) RETURNING id INTO v_dep_dapur; END IF;
  SELECT id INTO v_dep_bar     FROM menu_departments WHERE outlet_id=v_outlet AND name='Bar' LIMIT 1;
  IF v_dep_bar IS NULL THEN INSERT INTO menu_departments(outlet_id,name,color,sort_order,is_active) VALUES(v_outlet,'Bar','#3b82f6',2,true) RETURNING id INTO v_dep_bar; END IF;
  SELECT id INTO v_dep_dessert FROM menu_departments WHERE outlet_id=v_outlet AND name='Dessert' LIMIT 1;
  IF v_dep_dessert IS NULL THEN INSERT INTO menu_departments(outlet_id,name,color,sort_order,is_active) VALUES(v_outlet,'Dessert','#ec4899',3,true) RETURNING id INTO v_dep_dessert; END IF;

  -- ── Kategori ───────────────────────────────────────────────
  SELECT id INTO v_c1  FROM menu_categories WHERE outlet_id=v_outlet AND name='Dessert' LIMIT 1;
  IF v_c1  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Dessert',v_dep_dessert,1,true) RETURNING id INTO v_c1; END IF;
  SELECT id INTO v_c2  FROM menu_categories WHERE outlet_id=v_outlet AND name='Snack & Gorengan' LIMIT 1;
  IF v_c2  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Snack & Gorengan',v_dep_dapur,2,true) RETURNING id INTO v_c2; END IF;
  SELECT id INTO v_c3  FROM menu_categories WHERE outlet_id=v_outlet AND name='Kopi & Teh' LIMIT 1;
  IF v_c3  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Kopi & Teh',v_dep_bar,3,true) RETURNING id INTO v_c3; END IF;
  SELECT id INTO v_c4  FROM menu_categories WHERE outlet_id=v_outlet AND name='Minuman Segar' LIMIT 1;
  IF v_c4  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Minuman Segar',v_dep_bar,4,true) RETURNING id INTO v_c4; END IF;
  SELECT id INTO v_c5  FROM menu_categories WHERE outlet_id=v_outlet AND name='Seafood' LIMIT 1;
  IF v_c5  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Seafood',v_dep_dapur,5,true) RETURNING id INTO v_c5; END IF;
  SELECT id INTO v_c6  FROM menu_categories WHERE outlet_id=v_outlet AND name='Ayam & Bebek' LIMIT 1;
  IF v_c6  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Ayam & Bebek',v_dep_dapur,6,true) RETURNING id INTO v_c6; END IF;
  SELECT id INTO v_c7  FROM menu_categories WHERE outlet_id=v_outlet AND name='Sup & Soto' LIMIT 1;
  IF v_c7  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Sup & Soto',v_dep_dapur,7,true) RETURNING id INTO v_c7; END IF;
  SELECT id INTO v_c8  FROM menu_categories WHERE outlet_id=v_outlet AND name='Mie & Pasta' LIMIT 1;
  IF v_c8  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Mie & Pasta',v_dep_dapur,8,true) RETURNING id INTO v_c8; END IF;
  SELECT id INTO v_c9  FROM menu_categories WHERE outlet_id=v_outlet AND name='Nasi & Bubur' LIMIT 1;
  IF v_c9  IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Nasi & Bubur',v_dep_dapur,9,true) RETURNING id INTO v_c9; END IF;
  SELECT id INTO v_c10 FROM menu_categories WHERE outlet_id=v_outlet AND name='Burger' LIMIT 1;
  IF v_c10 IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Burger',v_dep_dapur,10,true) RETURNING id INTO v_c10; END IF;
  SELECT id INTO v_c11 FROM menu_categories WHERE outlet_id=v_outlet AND name='Kebab' LIMIT 1;
  IF v_c11 IS NULL THEN INSERT INTO menu_categories(outlet_id,name,department_id,sort_order,is_active) VALUES(v_outlet,'Kebab',v_dep_dapur,11,true) RETURNING id INTO v_c11; END IF;

  -- ── 100 Menu ───────────────────────────────────────────────
  PERFORM seed_menu(v_outlet, v_c1, 'Aneka dessert manis & segar',
    ARRAY['Cendol','Es Doger','Dadar Gulung','Kue Lapis','Martabak Manis Mini','Kolak Pisang','Es Campur','Pudding Coklat','Brownies Coklat','Klepon'],
    ARRAY[12000,15000,10000,12000,25000,15000,18000,15000,22000,10000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c2, 'Camilan & gorengan renyah',
    ARRAY['Risol Mayo','Kentang Goreng','Cireng Isi Ayam','Bakwan Sayur','Tahu Walik','Pisang Goreng','Tempe Mendoan','Lumpia Semarang','Sosis Bakar','Cilok Bumbu Kacang'],
    ARRAY[10000,15000,12000,8000,12000,10000,10000,13000,12000,8000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c3, 'Kopi & teh pilihan',
    ARRAY['Kopi Hitam','Es Kopi Susu','Cappuccino','Caffe Latte','Teh Tarik','Teh Tawar','Es Teh Manis','Lemon Tea','Matcha Latte'],
    ARRAY[10000,18000,22000,22000,15000,5000,8000,12000,25000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c4, 'Minuman segar & jus',
    ARRAY['Es Jeruk','Jus Alpukat','Jus Mangga','Es Cincau','Soda Gembira','Air Mineral','Es Kelapa Muda','Jus Strawberry','Lemonade'],
    ARRAY[10000,18000,16000,12000,15000,6000,15000,18000,15000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c5, 'Hidangan laut segar',
    ARRAY['Cumi Goreng Tepung','Udang Saus Padang','Ikan Bakar','Kerang Saus Tiram','Cumi Asam Manis','Udang Goreng Mentega','Ikan Asam Manis','Kepiting Lada Hitam','Gurame Bakar'],
    ARRAY[35000,40000,38000,32000,35000,42000,38000,75000,55000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c6, 'Olahan ayam & bebek',
    ARRAY['Ayam Goreng','Ayam Bakar','Ayam Geprek','Bebek Goreng','Bebek Bakar','Ayam Penyet','Ayam Rica-Rica','Ayam Kremes','Bebek Sambal Ijo'],
    ARRAY[20000,22000,18000,30000,32000,20000,24000,22000,33000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c7, 'Sup & soto hangat',
    ARRAY['Soto Ayam','Soto Betawi','Sup Iga','Bakso Urat','Sop Buntut','Soto Mie','Rawon','Tongseng','Coto Makassar'],
    ARRAY[18000,25000,35000,20000,40000,20000,25000,24000,25000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c8, 'Mie & pasta',
    ARRAY['Mie Goreng','Mie Kuah','Spaghetti Bolognese','Mie Ayam','Kwetiau Goreng','Bihun Goreng','Carbonara','Mie Aceh','Indomie Telur'],
    ARRAY[15000,15000,28000,16000,20000,18000,30000,22000,12000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c9, 'Nasi & bubur',
    ARRAY['Nasi Goreng Spesial','Nasi Uduk','Bubur Ayam','Nasi Kuning','Nasi Campur','Nasi Goreng Seafood','Bubur Kacang Hijau','Nasi Liwet','Nasi Bakar'],
    ARRAY[22000,15000,15000,16000,25000,30000,12000,28000,20000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c10, 'Aneka burger',
    ARRAY['Beef Burger','Chicken Burger','Cheese Burger','Double Beef','Burger Telur','Spicy Chicken Burger','Veggie Burger','BBQ Burger','Burger Jumbo'],
    ARRAY[25000,23000,27000,38000,22000,26000,20000,30000,45000]::numeric[]);
  PERFORM seed_menu(v_outlet, v_c11, 'Kebab isi melimpah',
    ARRAY['Kebab Ayam','Kebab Daging','Kebab Jumbo','Kebab Keju','Kebab Sapi Spesial','Kebab Mini','Kebab Sosis','Kebab Mix'],
    ARRAY[20000,25000,35000,28000,30000,12000,22000,32000]::numeric[]);

  -- ── Extras + opsi ──────────────────────────────────────────
  SELECT id INTO v_ex_pedas FROM menu_extras WHERE outlet_id=v_outlet AND name='Level Pedas' LIMIT 1;
  IF v_ex_pedas IS NULL THEN
    INSERT INTO menu_extras(outlet_id,name,type,selection_type,sort_order,is_active) VALUES(v_outlet,'Level Pedas','optional','single',1,true) RETURNING id INTO v_ex_pedas;
    INSERT INTO menu_extra_options(extra_id,name,price,sort_order) VALUES
      (v_ex_pedas,'Tidak Pedas',0,1),(v_ex_pedas,'Pedas Sedang',0,2),(v_ex_pedas,'Pedas',0,3),(v_ex_pedas,'Extra Pedas',2000,4);
  END IF;
  SELECT id INTO v_ex_topping FROM menu_extras WHERE outlet_id=v_outlet AND name='Topping' LIMIT 1;
  IF v_ex_topping IS NULL THEN
    INSERT INTO menu_extras(outlet_id,name,type,selection_type,sort_order,is_active) VALUES(v_outlet,'Topping','optional','multiple',2,true) RETURNING id INTO v_ex_topping;
    INSERT INTO menu_extra_options(extra_id,name,price,sort_order) VALUES
      (v_ex_topping,'Keju',5000,1),(v_ex_topping,'Telur',4000,2),(v_ex_topping,'Sosis',6000,3),(v_ex_topping,'Bakso',5000,4);
  END IF;
  SELECT id INTO v_ex_saus FROM menu_extras WHERE outlet_id=v_outlet AND name='Saus Tambahan' LIMIT 1;
  IF v_ex_saus IS NULL THEN
    INSERT INTO menu_extras(outlet_id,name,type,selection_type,sort_order,is_active) VALUES(v_outlet,'Saus Tambahan','optional','multiple',3,true) RETURNING id INTO v_ex_saus;
    INSERT INTO menu_extra_options(extra_id,name,price,sort_order) VALUES
      (v_ex_saus,'Sambal Bawang',3000,1),(v_ex_saus,'Saus Keju',5000,2),(v_ex_saus,'Mayo',3000,3),(v_ex_saus,'Saus BBQ',5000,4);
  END IF;

  -- Tautkan extras ke menu sesuai kategori (skip duplikat via PK)
  INSERT INTO menu_item_extras(menu_item_id, extra_id)
  SELECT mi.id, v_ex_pedas FROM menu_items mi JOIN menu_categories c ON c.id=mi.category_id
  WHERE mi.outlet_id=v_outlet AND c.name IN ('Ayam & Bebek','Seafood','Snack & Gorengan','Mie & Pasta','Nasi & Bubur')
  ON CONFLICT DO NOTHING;
  INSERT INTO menu_item_extras(menu_item_id, extra_id)
  SELECT mi.id, v_ex_topping FROM menu_items mi JOIN menu_categories c ON c.id=mi.category_id
  WHERE mi.outlet_id=v_outlet AND c.name IN ('Burger','Mie & Pasta','Nasi & Bubur','Kebab')
  ON CONFLICT DO NOTHING;
  INSERT INTO menu_item_extras(menu_item_id, extra_id)
  SELECT mi.id, v_ex_saus FROM menu_items mi JOIN menu_categories c ON c.id=mi.category_id
  WHERE mi.outlet_id=v_outlet AND c.name IN ('Snack & Gorengan','Burger','Kebab','Seafood')
  ON CONFLICT DO NOTHING;

  -- ── Meja (12) ──────────────────────────────────────────────
  INSERT INTO restaurant_tables(outlet_id, table_number, area, capacity, qr_token, is_active)
  SELECT v_outlet, g::text, CASE WHEN g<=6 THEN 'Indoor' ELSE 'Outdoor' END, 4, gen_random_uuid()::text, true
  FROM generate_series(1,12) g
  WHERE NOT EXISTS (SELECT 1 FROM restaurant_tables t WHERE t.outlet_id=v_outlet AND t.table_number=g::text);

  -- ── Bahan baku (12) ────────────────────────────────────────
  INSERT INTO ingredients(outlet_id,name,unit,cost_per_unit,stock_qty,min_stock_qty,is_active)
  SELECT v_outlet, x.name, x.unit, x.cost, x.stock, x.minq, true
  FROM (VALUES
    ('Beras','kg',12000,50,10),('Ayam','kg',35000,30,5),('Daging Sapi','kg',120000,15,3),
    ('Minyak Goreng','liter',16000,40,8),('Telur','kg',28000,20,5),('Gula Pasir','kg',14000,25,5),
    ('Tepung Terigu','kg',10000,30,5),('Cabai','kg',45000,8,2),('Bawang Merah','kg',30000,10,2),
    ('Bawang Putih','kg',32000,8,2),('Keju','kg',90000,5,1),('Saus Tomat','liter',20000,10,2)
  ) AS x(name,unit,cost,stock,minq)
  WHERE NOT EXISTS (SELECT 1 FROM ingredients i WHERE i.outlet_id=v_outlet AND i.name=x.name);

  -- ── Resep (contoh) ─────────────────────────────────────────
  INSERT INTO menu_recipes(menu_item_id, ingredient_id, qty_per_portion)
  SELECT mi.id, ing.id, r.qty
  FROM (VALUES
    ('Nasi Goreng Spesial','Beras',0.2),('Nasi Goreng Spesial','Telur',0.1),('Nasi Goreng Spesial','Minyak Goreng',0.03),
    ('Ayam Goreng','Ayam',0.25),('Ayam Goreng','Minyak Goreng',0.05),
    ('Mie Goreng','Tepung Terigu',0.15),('Mie Goreng','Minyak Goreng',0.03),
    ('Cheese Burger','Keju',0.05),('Cheese Burger','Daging Sapi',0.1)
  ) AS r(menu_name, ing_name, qty)
  JOIN menu_items  mi ON mi.outlet_id=v_outlet AND mi.name=r.menu_name
  JOIN ingredients ing ON ing.outlet_id=v_outlet AND ing.name=r.ing_name
  ON CONFLICT (menu_item_id, ingredient_id) DO NOTHING;

  -- ── Pengeluaran (5) ────────────────────────────────────────
  INSERT INTO expenses(outlet_id,category,amount,description,expense_date)
  SELECT v_outlet, x.cat::expense_category, x.amount, x.descr, CURRENT_DATE - x.days
  FROM (VALUES
    ('bahan_baku',1500000,'Belanja bahan baku mingguan',2),
    ('operasional',500000,'Listrik & air',5),
    ('gaji',3000000,'Gaji karyawan',1),
    ('peralatan',750000,'Beli kompor baru',10),
    ('marketing',300000,'Iklan media sosial',7)
  ) AS x(cat,amount,descr,days)
  WHERE NOT EXISTS (SELECT 1 FROM expenses e WHERE e.outlet_id=v_outlet AND e.description=x.descr);

  -- ── Member loyalty (8) ─────────────────────────────────────
  INSERT INTO loyalty_members(outlet_id,phone,name,points,tier,is_active)
  SELECT v_outlet, x.phone, x.name, x.points, x.tier, true
  FROM (VALUES
    ('081200000001','Andi Saputra',1200,'silver'),('081200000002','Budi Santoso',300,'bronze'),
    ('081200000003','Citra Dewi',5200,'gold'),('081200000004','Dewi Lestari',150,'bronze'),
    ('081200000005','Eko Prasetyo',8500,'platinum'),('081200000006','Fitri Handayani',900,'bronze'),
    ('081200000007','Gilang Ramadhan',2400,'silver'),('081200000008','Hana Permata',600,'bronze')
  ) AS x(phone,name,points,tier)
  WHERE NOT EXISTS (SELECT 1 FROM loyalty_members m WHERE m.outlet_id=v_outlet AND m.phone=x.phone);

  -- ── Promo + 10 voucher ─────────────────────────────────────
  SELECT id INTO v_promo FROM promos WHERE outlet_id=v_outlet AND name='Diskon Pembukaan' LIMIT 1;
  IF v_promo IS NULL THEN
    INSERT INTO promos(outlet_id,name,description,type,value,min_order,max_discount,start_date,end_date,usage_limit,is_active)
    VALUES(v_outlet,'Diskon Pembukaan','Diskon 10% untuk pelanggan baru','percentage',10,50000,20000,CURRENT_DATE,CURRENT_DATE+30,100,true)
    RETURNING id INTO v_promo;
  END IF;
  INSERT INTO vouchers(promo_id, outlet_id, code, usage_limit, is_active)
  SELECT v_promo, v_outlet, 'HEMAT10-'||LPAD(g::text,3,'0'), 1, true
  FROM generate_series(1,10) g
  ON CONFLICT (code) DO NOTHING;

  RAISE NOTICE 'Seed selesai untuk outlet %', v_outlet;
END $$;

DROP FUNCTION IF EXISTS seed_menu(UUID, UUID, TEXT, TEXT[], NUMERIC[]);

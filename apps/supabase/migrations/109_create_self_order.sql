-- 109_create_self_order.sql
-- Self-order (QR pelanggan): pembuatan pesanan ATOMIK + total dihitung SERVER +
-- rem anti-spam, plus RPC riwayat order untuk pelanggan (anon).
--
-- (A) ATOMICITY. Dulu 3 INSERT terpisah dari klien (orders → items → options);
--     putus koneksi di tengah = order tanpa item / item tanpa opsi. Kini satu
--     fungsi = satu transaksi.
--
-- (B) TOTAL DIHITUNG ULANG DI SERVER. Dulu subtotal/pajak/service/total dikirim
--     browser apa adanya → pelanggan bisa mengarang total=0. Kini server
--     menghitung dari item (unit_price sudah dijaga trigger >= harga katalog) +
--     pajak/service dari settings outlet. Diskon dibatasi [0, subtotal].
--
-- (C) ANTI-SPAM. Cooldown per meja + batas order aktif per meja per hari,
--     supaya anon tak bisa membanjiri dapur/kasir dengan draft.

-- Catatan order-level (mis. "pedas sedikit") — tabel orders belum punya kolom
-- ini (notes hanya ada di order_items). Tambah agar catatan pelanggan tersimpan.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS notes TEXT;

CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id        UUID,
  p_table_id         UUID,
  p_items            JSONB,   -- [{menu_item_id, quantity, unit_price, notes,
                              --   options:[{menu_extra_id, menu_extra_option_id,
                              --             extra_name, option_name, price}]}]
  p_customer_name    TEXT    DEFAULT NULL,
  p_notes            TEXT    DEFAULT NULL,
  p_discount_amount  NUMERIC DEFAULT 0,
  p_loyalty_discount NUMERIC DEFAULT 0,
  p_redeemed_points  INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id     UUID := gen_random_uuid();
  v_order_number TEXT;
  v_item         JSONB;
  v_item_id      UUID;
  v_opt          JSONB;
  v_settings     JSONB;
  v_tax_pct      NUMERIC := 0;
  v_svc_pct      NUMERIC := 0;
  v_qty          INTEGER;
  v_unit         NUMERIC;
  v_subtotal     NUMERIC := 0;
  v_disc         NUMERIC;
  v_loy          NUMERIC;
  v_tax          NUMERIC;
  v_svc          NUMERIC;
  v_total        NUMERIC;
  v_active       INTEGER;
BEGIN
  IF p_outlet_id IS NULL OR p_table_id IS NULL THEN
    RAISE EXCEPTION 'Outlet & meja wajib diisi';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Keranjang kosong';
  END IF;

  -- ── (C) Anti-spam ──────────────────────────────────────────────────────────
  -- Cooldown: tolak bila ada order utk meja ini < 15 detik lalu (cegah
  -- double-tap / banjir cepat).
  IF EXISTS (
    SELECT 1 FROM orders
    WHERE table_id = p_table_id
      AND created_at > now() - interval '15 seconds'
  ) THEN
    RAISE EXCEPTION 'Pesanan baru saja dibuat. Tunggu sebentar lalu coba lagi.';
  END IF;

  -- Batas order SELF-ORDER aktif (belum selesai) per meja hari ini. Hanya
  -- hitung self_order — order kasir (POS) di meja yang sama tak boleh ikut
  -- memblokir pelanggan. Anti-spam ini soal banjir anon lewat QR, bukan
  -- transaksi sah kasir.
  SELECT count(*) INTO v_active
  FROM orders
  WHERE table_id = p_table_id
    AND order_type = 'self_order'
    AND status NOT IN ('paid', 'cancelled', 'void')
    AND (created_at AT TIME ZONE 'Asia/Jakarta')::date
        = (now() AT TIME ZONE 'Asia/Jakarta')::date;
  IF v_active >= 15 THEN
    RAISE EXCEPTION 'Meja ini punya terlalu banyak pesanan aktif. Panggil kasir.';
  END IF;

  -- ── (B) Hitung ulang total dari item + settings outlet ─────────────────────
  SELECT settings INTO v_settings FROM outlets WHERE id = p_outlet_id;
  IF v_settings IS NOT NULL THEN
    IF COALESCE((v_settings->>'tax_active')::boolean, true) THEN
      v_tax_pct := COALESCE((v_settings->>'tax_percent')::numeric, 0);
    END IF;
    v_svc_pct := COALESCE((v_settings->>'service_charge_percent')::numeric, 0);
  END IF;

  -- Subtotal server-side (abaikan angka klien). unit_price dijaga trigger
  -- validate_order_item_price >= harga katalog saat INSERT order_items.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty  := GREATEST(COALESCE((v_item->>'quantity')::int, 0), 0);
    v_unit := GREATEST(COALESCE((v_item->>'unit_price')::numeric, 0), 0);
    v_subtotal := v_subtotal + v_qty * v_unit;
  END LOOP;

  -- Diskon dibatasi agar tak melebihi subtotal (cegah total negatif/nol palsu).
  v_disc := LEAST(GREATEST(COALESCE(p_discount_amount, 0), 0), v_subtotal);
  v_loy  := LEAST(GREATEST(COALESCE(p_loyalty_discount, 0), 0), v_subtotal - v_disc);
  v_tax  := round(v_subtotal * v_tax_pct / 100);
  v_svc  := round(v_subtotal * v_svc_pct / 100);
  v_total := GREATEST(0, v_subtotal - v_disc - v_loy) + v_tax + v_svc;

  v_order_number := get_next_order_number(p_outlet_id);

  INSERT INTO orders (
    id, outlet_id, table_id, order_number, order_type, status,
    customer_name, subtotal, discount_amount, loyalty_discount,
    redeemed_points, tax_amount, service_charge, total_amount, notes
  ) VALUES (
    v_order_id, p_outlet_id, p_table_id, v_order_number, 'self_order', 'draft',
    p_customer_name, v_subtotal, v_disc, v_loy,
    GREATEST(COALESCE(p_redeemed_points, 0), 0), v_tax, v_svc, v_total, p_notes
  );

  -- ── (A) Item + opsi dalam transaksi yang sama ──────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_item_id := gen_random_uuid();
    v_qty  := GREATEST(COALESCE((v_item->>'quantity')::int, 0), 0);
    v_unit := GREATEST(COALESCE((v_item->>'unit_price')::numeric, 0), 0);
    IF v_qty = 0 THEN CONTINUE; END IF;

    INSERT INTO order_items (
      id, order_id, menu_item_id, quantity, unit_price, subtotal, notes
    ) VALUES (
      v_item_id, v_order_id,
      (v_item->>'menu_item_id')::uuid,
      v_qty, v_unit, v_qty * v_unit,
      NULLIF(v_item->>'notes', '')
    );

    IF (v_item ? 'options') AND jsonb_typeof(v_item->'options') = 'array' THEN
      FOR v_opt IN SELECT * FROM jsonb_array_elements(v_item->'options') LOOP
        INSERT INTO order_item_options (
          order_item_id, menu_extra_id, menu_extra_option_id,
          extra_name, option_name, price
        ) VALUES (
          v_item_id,
          (v_opt->>'menu_extra_id')::uuid,
          (v_opt->>'menu_extra_option_id')::uuid,
          v_opt->>'extra_name',
          v_opt->>'option_name',
          COALESCE((v_opt->>'price')::numeric, 0)
        );
      END LOOP;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'total_amount', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
) TO anon, authenticated;

-- ── Riwayat order pelanggan (anon) ───────────────────────────────────────────
-- Pelanggan menyimpan id order miliknya di localStorage; RPC ini mengembalikan
-- ringkasan + status TERKINI untuk id-id itu. Hanya order yang id-nya dipegang
-- pemesan yang terlihat (id acak = kapabilitas), jadi tak membocorkan meja lain.
CREATE OR REPLACE FUNCTION public.get_self_orders(p_ids UUID[])
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'created_at' DESC), '[]'::jsonb)
  FROM (
    SELECT jsonb_build_object(
      'id',           o.id,
      'order_number', o.order_number,
      'status',       o.status,
      'total_amount', o.total_amount,
      'created_at',   o.created_at,
      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'name', mi.name, 'quantity', oi.quantity))
        FROM order_items oi
        JOIN menu_items mi ON mi.id = oi.menu_item_id
        WHERE oi.order_id = o.id
      ), '[]'::jsonb)
    ) AS row
    FROM orders o
    WHERE o.id = ANY(p_ids)
      AND o.order_type = 'self_order'
  ) t;
$$;

REVOKE ALL ON FUNCTION public.get_self_orders(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_self_orders(UUID[]) TO anon, authenticated;

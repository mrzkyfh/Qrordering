-- 114_self_order_tax_inclusive.sql
-- Hormati `tax_inclusive` saat server menghitung total self-order.
--
-- Konteks: setelan "Harga Sudah Termasuk Pajak" sudah lama ada di owner-panel &
-- aplikasi, dan STRUK sudah menghormatinya (mencetak "Harga Sudah Termasuk PPN
-- senilai X" alih-alih baris pajak terpisah). Tapi PERHITUNGANNYA — di POS
-- maupun di sini — mengabaikannya: pajak tetap ditambahkan di atas subtotal.
-- Akibatnya, begitu setelan itu dinyalakan, pelanggan tertagih pajak dobel
-- sementara struk menyatakan pajak sudah termasuk harga.
--
-- Perbaikan (identik dengan PosState.taxAmount/total di aplikasi & tampilan
-- keranjang customer-menu, supaya ketiganya tidak berbeda diam-diam):
--   inclusive = false → v_tax = round(subtotal × p/100)          , total += v_tax
--   inclusive = true  → v_tax = round(subtotal − subtotal/(1+p)) , total TIDAK += v_tax
-- Pada mode inclusive, v_tax adalah komponen pajak yang DIPISAHKAN dari harga
-- untuk struk & laporan; nilainya sudah termuat di dalam subtotal.
--
-- Salinan setia 109 — HANYA blok perhitungan pajak yang berubah (ditandai
-- "◄ 114"). Signature, anti-spam, insert item+opsi, status draft, return, dan
-- grant dipertahankan persis; mengubahnya di sini akan memutus self-order.

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
  v_tax_incl     BOOLEAN := false;   -- ◄ 114
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
    v_tax_incl := COALESCE((v_settings->>'tax_inclusive')::boolean, false);  -- ◄ 114
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

  -- ◄ 114: harga sudah memuat pajak → pisahkan, jangan tambahkan lagi.
  IF v_tax_incl AND v_tax_pct > 0 THEN
    v_tax := round(v_subtotal - v_subtotal / (1 + v_tax_pct / 100));
  ELSE
    v_tax := round(v_subtotal * v_tax_pct / 100);
  END IF;
  v_svc := round(v_subtotal * v_svc_pct / 100);
  v_total := GREATEST(0, v_subtotal - v_disc - v_loy)
             + (CASE WHEN v_tax_incl THEN 0 ELSE v_tax END)   -- ◄ 114
             + v_svc;

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

-- Grant dipertahankan (CREATE OR REPLACE tidak mengubahnya, tapi ditegaskan
-- agar migration ini tetap benar bila dijalankan di DB yang dibangun dari nol).
REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
) TO anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
) IS
  'Self-order atomik: total dihitung SERVER (klien tak dipercaya) + anti-spam. '
  'Menghormati tax_inclusive — harga yang sudah memuat pajak tidak ditambahi '
  'lagi; pajaknya dipisahkan untuk struk & laporan. Rumus identik dengan '
  'PosState di aplikasi.';

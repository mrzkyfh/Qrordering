-- 129_self_order_authoritative_prices.sql
-- Pelanggan QR MASIH bisa memesan (nyaris) gratis — lewat harga, bukan diskon.
--
-- ── Apa yang 125 tutup, dan apa yang TIDAK ──────────────────────────────────
-- 125 memindahkan DISKON ke server: klien tak lagi mengirim nominal diskon.
-- Header-nya berbunyi "TOTAL DIHITUNG ULANG DI SERVER". Tapi total itu dihitung
-- ulang dari HARGA YANG DIKIRIM KLIEN:
--
--     v_unit := GREATEST(COALESCE((v_item->>'unit_price')::numeric, 0), 0);
--     v_subtotal := v_subtotal + v_qty * v_unit;              -- ← harga klien
--     ...
--     price = COALESCE((v_opt->>'price')::numeric, 0)         -- ← harga klien
--
-- menu_items.price / menu_extra_options.price TIDAK PERNAH dibaca. create_self_order
-- SECURITY DEFINER & ter-grant ke anon, jadi menu QR memanggilnya langsung.
-- Siapa pun bisa mencegat request dan mengirim unit_price: 0 untuk item Rp 100.000
-- → order tersimpan subtotal ≈ 0, total ≈ 0. Persis kelas "pesan Rp 0" yang 125
-- klaim sudah ditutup — hanya vektornya yang bergeser dari diskon ke harga dasar.
--
-- Order masuk sebagai 'self_order'/'draft', jadi kasir MELIHATNya — tapi total
-- yang ia tagih (dan tiket dapur) memakai angka order dari DB yang sudah palsu.
-- Kasir yang percaya total sistem menagih Rp 0.
--
-- ── Perbaikan: harga OTORITATIF dari DB ─────────────────────────────────────
-- unit_price & options.price dari klien DIABAIKAN. Untuk tiap item:
--   • harga dasar  = menu_items.price  (WHERE outlet + is_active + is_available)
--   • harga opsi   = menu_extra_options.price, dan opsi WAJIB tertaut ke item
--                    yang dipesan (menu_item_extras) — mencegah menempelkan opsi
--                    murah/asing dari item lain.
-- Item/opsi yang tak lolos → DITOLAK (bukan diam-diam dihargai 0). Kontrak lama
-- dipertahankan: order_items.unit_price = harga_dasar + Σ harga_opsi, dan tiap
-- order_item_options.price memakai harga DB.
--
-- Sisa fungsi (anti-spam, promo/loyalty server-side dari 125, pemotongan poin
-- atomik, nilai balik) TIDAK berubah. Tanda tangan dipertahankan PERSIS agar
-- CREATE OR REPLACE menimpa, bukan membuat overload.

-- Harga satuan OTORITATIF satu baris keranjang: harga_dasar(menu_items) +
-- Σ harga_opsi(menu_extra_options). MELEMPAR bila menu tak tersedia di outlet
-- ini, atau bila ada opsi yang tak tertaut ke menu tsb (menu_item_extras).
-- Internal — hanya dipanggil create_self_order (yang SECURITY DEFINER), tak
-- di-grant ke anon.
CREATE OR REPLACE FUNCTION public._self_order_line(p_outlet_id UUID, p_item JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_mid    UUID := (p_item->>'menu_item_id')::uuid;
  v_base   NUMERIC;
  v_extras NUMERIC := 0;
  v_nopt   INT := 0;
  v_nmatch INT := 0;
BEGIN
  SELECT price INTO v_base FROM menu_items
  WHERE id = v_mid AND outlet_id = p_outlet_id AND is_active AND is_available;
  IF v_base IS NULL THEN
    RAISE EXCEPTION 'Menu tidak tersedia (item %)', v_mid;
  END IF;

  IF (p_item ? 'options') AND jsonb_typeof(p_item->'options') = 'array' THEN
    SELECT count(*) INTO v_nopt FROM jsonb_array_elements(p_item->'options');
    -- Hanya opsi yang BENAR tertaut ke item ini yang ikut ter-join; bila ada
    -- yang tak cocok, v_nmatch < v_nopt → tolak (mencegah opsi asing/palsu).
    SELECT COALESCE(SUM(meo.price), 0), count(*)
      INTO v_extras, v_nmatch
    FROM jsonb_array_elements(p_item->'options') o
    JOIN menu_extra_options meo ON meo.id = (o->>'menu_extra_option_id')::uuid
    JOIN menu_item_extras  mie ON mie.extra_id = meo.extra_id
                              AND mie.menu_item_id = v_mid;
    IF v_nmatch <> v_nopt THEN
      RAISE EXCEPTION 'Opsi tidak valid untuk menu ini';
    END IF;
  END IF;

  RETURN v_base + v_extras;
END $$;

REVOKE ALL ON FUNCTION public._self_order_line(UUID, JSONB) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id     UUID,
  p_table_id      UUID,
  p_items         JSONB,
  p_customer_name TEXT    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_promo_code    TEXT    DEFAULT NULL,
  p_member_id     UUID    DEFAULT NULL,
  p_redeem_points INTEGER DEFAULT 0
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
  v_mid          UUID;      -- ◄ 129 menu_item_id item berjalan
  v_settings     JSONB;
  v_tax_pct      NUMERIC := 0;
  v_tax_incl     BOOLEAN := false;
  v_svc_pct      NUMERIC := 0;
  v_qty          INTEGER;
  v_unit         NUMERIC;   -- ◄ 129 harga satuan OTORITATIF (dari _self_order_line)
  v_subtotal     NUMERIC := 0;
  v_disc         NUMERIC := 0;
  v_loy          NUMERIC := 0;
  v_pts          INTEGER := 0;
  v_promo        JSON;
  v_promo_id     UUID;
  v_voucher_id   UUID;
  v_redeem       JSON;
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
  IF EXISTS (
    SELECT 1 FROM orders
    WHERE table_id = p_table_id
      AND created_at > now() - interval '15 seconds'
  ) THEN
    RAISE EXCEPTION 'Pesanan baru saja dibuat. Tunggu sebentar lalu coba lagi.';
  END IF;

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

  -- ── Settings outlet (pajak/service) ────────────────────────────────────────
  SELECT settings INTO v_settings FROM outlets WHERE id = p_outlet_id;
  IF v_settings IS NOT NULL THEN
    IF COALESCE((v_settings->>'tax_active')::boolean, true) THEN
      v_tax_pct := COALESCE((v_settings->>'tax_percent')::numeric, 0);
    END IF;
    v_tax_incl := COALESCE((v_settings->>'tax_inclusive')::boolean, false);
    v_svc_pct  := COALESCE((v_settings->>'service_charge_percent')::numeric, 0);
  END IF;

  -- ── (B) Subtotal dari harga OTORITATIF DB (◄ 129) ──────────────────────────
  -- _self_order_line() mengembalikan harga satuan sah (dasar + Σ opsi) & MELEMPAR
  -- bila item/opsi tak sah. Dipakai di sini DAN di loop insert → satu sumber.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := GREATEST(COALESCE((v_item->>'quantity')::int, 0), 0);
    IF v_qty = 0 THEN CONTINUE; END IF;
    v_subtotal := v_subtotal + v_qty * _self_order_line(p_outlet_id, v_item);
  END LOOP;

  IF v_subtotal <= 0 THEN
    RAISE EXCEPTION 'Pesanan tidak valid';
  END IF;

  -- ── Diskon DIHITUNG server (125), bukan diterima dari klien ────────────────
  IF p_promo_code IS NOT NULL AND btrim(p_promo_code) <> '' THEN
    v_promo      := validate_promo_code(btrim(p_promo_code), p_outlet_id, v_subtotal);
    v_disc       := GREATEST(COALESCE((v_promo->>'discount_amount')::numeric, 0), 0);
    v_promo_id   := NULLIF(v_promo->>'promo_id', '')::uuid;
    v_voucher_id := NULLIF(v_promo->>'voucher_id', '')::uuid;
  END IF;

  IF p_member_id IS NOT NULL AND COALESCE(p_redeem_points, 0) > 0 THEN
    v_redeem := validate_loyalty_redeem(p_member_id, p_redeem_points, v_subtotal, v_disc);
    v_loy    := GREATEST(COALESCE((v_redeem->>'discount_amount')::numeric, 0), 0);
    v_pts    := GREATEST(COALESCE((v_redeem->>'points_used')::int, 0), 0);
  END IF;

  v_disc := LEAST(v_disc, v_subtotal);
  v_loy  := LEAST(v_loy, GREATEST(v_subtotal - v_disc, 0));

  IF v_tax_incl AND v_tax_pct > 0 THEN
    v_tax := round(v_subtotal - v_subtotal / (1 + v_tax_pct / 100));
  ELSE
    v_tax := round(v_subtotal * v_tax_pct / 100);
  END IF;
  v_svc := round(v_subtotal * v_svc_pct / 100);
  v_total := GREATEST(0, v_subtotal - v_disc - v_loy)
             + (CASE WHEN v_tax_incl THEN 0 ELSE v_tax END)
             + v_svc;

  v_order_number := get_next_order_number(p_outlet_id);

  INSERT INTO orders (
    id, outlet_id, table_id, order_number, order_type, status,
    customer_name, subtotal, discount_amount, loyalty_discount,
    loyalty_member_id,
    redeemed_points, tax_amount, service_charge, total_amount, notes,
    tax_inclusive
  ) VALUES (
    v_order_id, p_outlet_id, p_table_id, v_order_number, 'self_order', 'draft',
    p_customer_name, v_subtotal, v_disc, v_loy,
    CASE WHEN v_pts > 0 THEN p_member_id ELSE NULL END,
    v_pts, v_tax, v_svc, v_total, p_notes,
    v_tax_incl
  );

  -- ── (A) Item + opsi, harga OTORITATIF (◄ 129) ──────────────────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := GREATEST(COALESCE((v_item->>'quantity')::int, 0), 0);
    IF v_qty = 0 THEN CONTINUE; END IF;
    v_mid  := (v_item->>'menu_item_id')::uuid;
    v_unit := _self_order_line(p_outlet_id, v_item);     -- dasar + Σ opsi (DB)
    v_item_id := gen_random_uuid();

    -- Induk DULU (order_item_options ber-FK ke order_items.id).
    INSERT INTO order_items (
      id, order_id, menu_item_id, quantity, unit_price, subtotal, notes
    ) VALUES (
      v_item_id, v_order_id, v_mid,
      v_qty, v_unit, v_qty * v_unit,
      NULLIF(v_item->>'notes', '')
    );

    -- Opsi: harga dari DB (bukan dari klien), berbasis-himpunan. _self_order_line
    -- sudah memvalidasi semua opsi tertaut, jadi join di sini pasti lengkap.
    IF (v_item ? 'options') AND jsonb_typeof(v_item->'options') = 'array' THEN
      INSERT INTO order_item_options (
        order_item_id, menu_extra_id, menu_extra_option_id,
        extra_name, option_name, price
      )
      SELECT v_item_id, meo.extra_id, meo.id,
             o->>'extra_name', o->>'option_name', meo.price   -- ◄ 129 harga DB
      FROM jsonb_array_elements(v_item->'options') o
      JOIN menu_extra_options meo ON meo.id = (o->>'menu_extra_option_id')::uuid
      JOIN menu_item_extras  mie ON mie.extra_id = meo.extra_id
                                AND mie.menu_item_id = v_mid;
    END IF;
  END LOOP;

  -- Klaim pemakaian promo (idempoten per order; wajib order nyata — 076).
  IF v_promo_id IS NOT NULL OR v_voucher_id IS NOT NULL THEN
    PERFORM apply_promo_usage(v_promo_id, v_voucher_id, v_order_id);
  END IF;

  -- Potong poin, atomik dengan pembuatan order (125). redeem_loyalty_points
  -- menghitung ulang diskonnya sendiri & menimpa orders.loyalty_discount;
  -- trigger enforce_order_total (116) menurunkan ulang totalnya.
  IF v_pts > 0 AND p_member_id IS NOT NULL THEN
    PERFORM redeem_loyalty_points(v_order_id, p_member_id, v_pts);
    SELECT total_amount, loyalty_discount INTO v_total, v_loy
      FROM orders WHERE id = v_order_id;
  END IF;

  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'discount_amount', v_disc,
    'loyalty_discount', v_loy,
    'points_used', v_pts,
    'total_amount', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) TO anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) IS
  'Self-order atomik + anti-spam. HARGA, diskon, & total dihitung SERVER dari '
  'menu_items/menu_extra_options — unit_price & options.price dari klien '
  'diabaikan (129). Klien hanya menyebut item, kode promo, & jumlah poin. '
  'Sebelum 129 subtotal dibangun dari harga kiriman klien → pesan Rp 0 lewat '
  'unit_price palsu; sebelum 125 nominal diskon juga dari klien.';

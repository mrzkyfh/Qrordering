-- 125_self_order_server_side_discount.sql
-- Pelanggan QR bisa memesan GRATIS. Diskon selama ini ditentukan klien.
--
-- ── Bukti (tereproduksi di Postgres lokal) ──────────────────────────────────
-- Anon memanggil create_self_order dengan p_discount_amount = 500000 untuk
-- Steak Rp 500.000 → order tersimpan dengan total Rp 0. Tanpa promo apa pun,
-- tanpa jadi member.
--
-- ── Kenapa lolos ────────────────────────────────────────────────────────────
-- Header 109 berbunyi:
--     "(B) TOTAL DIHITUNG ULANG DI SERVER. Dulu subtotal/pajak/service/total
--      dikirim browser apa adanya → pelanggan bisa mengarang total=0. Kini
--      server menghitung... Diskon dibatasi [0, subtotal]."
-- Totalnya memang diperbaiki — tapi INPUT diskonnya tetap dari klien, dan
-- "dibatasi ke subtotal" itu justru YANG MEMUNGKINKAN total nol. Clamp bukan
-- pengaman; ia izin diskon 100%. Tujuan yang tertulis di 109 tak pernah tercapai.
--
-- ── Perbaikan ───────────────────────────────────────────────────────────────
-- Klien tidak lagi mengirim NOMINAL diskon. Ia hanya menyebut NIAT:
--   • p_promo_code   → server memvalidasi & menghitung sendiri (validate_promo_code)
--   • p_member_id + p_redeem_points → server menghitung dari redeem_rate
--     (validate_loyalty_redeem) & memverifikasi saldo poin member cukup
-- Nominal diskon menjadi turunan, bukan masukan. Prinsip yang sama dengan
-- total_amount (116) dan expected_cash (119).
--
-- Bonus yang ikut beres: order self-order kini TERHUBUNG ke membernya
-- (loyalty_member_id). Dulu kolom itu tak pernah diisi, sehingga poin tak
-- pernah bisa dipotong saat pembayaran.
--
-- ⚠️ TANDA TANGAN BERUBAH → deploy migration & kedua klien BERSAMAAN.
-- p_discount_amount/p_loyalty_discount/p_redeemed_points DIHAPUS; menyisakannya
-- sebagai parameter yang diabaikan hanya akan menipu pembaca berikutnya.
-- Fungsi lama di-DROP: menambah parameter lewat CREATE OR REPLACE membuat
-- OVERLOAD, bukan pengganti — dan panggilan lama jadi ambigu.

DROP FUNCTION IF EXISTS public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER
);

CREATE FUNCTION public.create_self_order(
  p_outlet_id     UUID,
  p_table_id      UUID,
  p_items         JSONB,   -- [{menu_item_id, quantity, unit_price, notes,
                           --   options:[{menu_extra_id, menu_extra_option_id,
                           --             extra_name, option_name, price}]}]
  p_customer_name TEXT    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_promo_code    TEXT    DEFAULT NULL,   -- ◄ 125 (bukan nominal)
  p_member_id     UUID    DEFAULT NULL,   -- ◄ 125
  p_redeem_points INTEGER DEFAULT 0       -- ◄ 125
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
  v_tax_incl     BOOLEAN := false;
  v_svc_pct      NUMERIC := 0;
  v_qty          INTEGER;
  v_unit         NUMERIC;
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

  -- ── (B) Hitung ulang total dari item + settings outlet ─────────────────────
  SELECT settings INTO v_settings FROM outlets WHERE id = p_outlet_id;
  IF v_settings IS NOT NULL THEN
    IF COALESCE((v_settings->>'tax_active')::boolean, true) THEN
      v_tax_pct := COALESCE((v_settings->>'tax_percent')::numeric, 0);
    END IF;
    v_tax_incl := COALESCE((v_settings->>'tax_inclusive')::boolean, false);
    v_svc_pct  := COALESCE((v_settings->>'service_charge_percent')::numeric, 0);
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty  := GREATEST(COALESCE((v_item->>'quantity')::int, 0), 0);
    v_unit := GREATEST(COALESCE((v_item->>'unit_price')::numeric, 0), 0);
    v_subtotal := v_subtotal + v_qty * v_unit;
  END LOOP;

  -- ── ◄ 125 Diskon DIHITUNG server, bukan diterima dari klien ────────────────
  IF p_promo_code IS NOT NULL AND btrim(p_promo_code) <> '' THEN
    -- Melempar bila kode tak sah/kedaluwarsa/habis — pesanan dengan promo palsu
    -- ditolak, bukan diam-diam diberi diskon.
    v_promo      := validate_promo_code(btrim(p_promo_code), p_outlet_id, v_subtotal);
    v_disc       := GREATEST(COALESCE((v_promo->>'discount_amount')::numeric, 0), 0);
    v_promo_id   := NULLIF(v_promo->>'promo_id', '')::uuid;
    v_voucher_id := NULLIF(v_promo->>'voucher_id', '')::uuid;
  END IF;

  IF p_member_id IS NOT NULL AND COALESCE(p_redeem_points, 0) > 0 THEN
    -- Memverifikasi member aktif & saldo poin cukup; menghitung diskon dari
    -- redeem_rate outlet, lalu membatasinya ke (subtotal − diskon promo).
    v_redeem := validate_loyalty_redeem(p_member_id, p_redeem_points, v_subtotal, v_disc);
    v_loy    := GREATEST(COALESCE((v_redeem->>'discount_amount')::numeric, 0), 0);
    v_pts    := GREATEST(COALESCE((v_redeem->>'points_used')::int, 0), 0);
  END IF;

  -- Jaring pengaman: diskon tak boleh melebihi subtotal walau validator meleset.
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
    loyalty_member_id,                                     -- ◄ 125
    redeemed_points, tax_amount, service_charge, total_amount, notes,
    tax_inclusive
  ) VALUES (
    v_order_id, p_outlet_id, p_table_id, v_order_number, 'self_order', 'draft',
    p_customer_name, v_subtotal, v_disc, v_loy,
    CASE WHEN v_pts > 0 THEN p_member_id ELSE NULL END,    -- ◄ 125
    v_pts, v_tax, v_svc, v_total, p_notes,
    v_tax_incl
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

  -- Klaim pemakaian promo (idempoten per order; wajib order nyata — 076).
  IF v_promo_id IS NOT NULL OR v_voucher_id IS NOT NULL THEN
    PERFORM apply_promo_usage(v_promo_id, v_voucher_id, v_order_id);
  END IF;

  -- ◄ 125 POTONG poinnya sungguhan, dalam transaksi yang sama.
  --
  -- Dulu app.js yang memanggil redeem_loyalty_points setelah order dibuat —
  -- padahal 069 mencabutnya dari anon, jadi panggilan itu SELALU gagal 42501 dan
  -- ditelan try/catch. Akibatnya: begitu diskon poin bisa dipakai, pelanggan
  -- mendapat potongan tanpa poinnya pernah berkurang — berulang kali.
  --
  -- Dikerjakan di sini karena fungsi ini SECURITY DEFINER: pemotongan menjadi
  -- atomik dengan pembuatan ordernya (tak ada order berdiskon tanpa poin
  -- terpotong), dan anon TIDAK perlu diberi akses langsung ke
  -- redeem_loyalty_points — yang akan membiarkan siapa pun menguras poin orang
  -- lain. redeem_loyalty_points menghitung ulang diskonnya sendiri dari
  -- redeem_rate & menimpa orders.loyalty_discount; trigger enforce_order_total
  -- (116) lalu menurunkan ulang totalnya. Jadi angkanya tetap konsisten.
  IF v_pts > 0 AND p_member_id IS NOT NULL THEN
    PERFORM redeem_loyalty_points(v_order_id, p_member_id, v_pts);
    SELECT total_amount, loyalty_discount INTO v_total, v_loy
      FROM orders WHERE id = v_order_id;
  END IF;

  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'discount_amount', v_disc,        -- ◄ 125 klien menampilkan angka SERVER
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
  'Self-order atomik + anti-spam. Total DAN diskon dihitung SERVER: klien hanya '
  'menyebut kode promo & jumlah poin, bukan nominalnya. Sebelumnya klien '
  'mengirim nominal diskon yang cuma dibatasi ke subtotal — sehingga pelanggan '
  'bisa memesan dengan total Rp 0 tanpa promo apa pun.';

-- ── Kembalikan grant yang dicabut 069 ────────────────────────────────────────
-- 069 (pembersihan linter) mencabut validate_loyalty_redeem dari anon, padahal
-- menu QR pelanggan memanggilnya → tukar poin GAGAL 42501 di produksi sampai
-- hari ini. Kelas regresi yang sama sudah ditambal 082 untuk auth helper
-- ("FIX REGRESI: migration 069 mencabut EXECUTE ... dari anon"), tapi yang ini
-- terlewat. Fungsinya read-only (hanya memvalidasi & menghitung) dan butuh
-- member_id yang memang sudah bisa didapat anon lewat
-- find_loyalty_member_by_phone — jadi tak menambah permukaan.
GRANT EXECUTE ON FUNCTION validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC)
  TO anon;

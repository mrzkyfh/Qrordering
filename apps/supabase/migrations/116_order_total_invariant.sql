-- 116_order_total_invariant.sql
-- Jadikan SERVER sumber kebenaran untuk orders.total_amount.
--
-- MASALAH. Untuk self-order, server sudah menghitung ulang semuanya — alasannya
-- ditulis terang-terangan di 109: "pelanggan bisa mengarang total=0". Kecurigaan
-- yang sama TIDAK pernah diterapkan ke jalur kasir: total_amount,
-- discount_amount, dan payments.amount ditulis apa adanya dari klien, dan tidak
-- ada satu pun trigger/CHECK yang memverifikasi bahwa total = jumlah komponennya.
--
-- Akibatnya nyata, bukan teoretis:
--   • redeem_loyalty_points MENIMPA loyalty_discount dengan hitungan server tapi
--     tak pernah menghitung ulang total_amount → baris order jadi tak konsisten,
--     sementara pelanggan sudah membayar angka lama.
--   • Dua bug pajak (tax_inclusive diabaikan POS; open-bill menghitung pajak
--     tanpa memandang tax_inclusive) menghasilkan total salah yang diterima DB
--     tanpa berkedip, dan baru ketahuan lewat audit berbulan-bulan kemudian.
--   • merge_orders menjumlahkan semua komponen KECUALI loyalty_discount →
--     barisnya tak konsisten sejak dibuat (ikut dibereskan di bawah).
--
-- Invariant menangkap kesalahan yang TIDAK terpikirkan siapa pun; test hanya
-- menangkap yang sudah terpikirkan. Itulah kenapa ini dipasang di DB.
--
-- ── Keputusan rancangan ─────────────────────────────────────────────────────
--
-- (1) Total dihitung dari KOMPONEN MILIK ORDER ITU SENDIRI, bukan dari setelan
--     outlet saat ini. Kalau membaca settings, order offline yang tersinkron
--     3 hari kemudian — setelah owner mengubah pajak 10%→11% — akan dihitung
--     ulang memakai tarif baru, padahal pelanggan sudah membayar tarif lama.
--     Karena itu perlakuan pajak di-SNAPSHOT di kolom orders.tax_inclusive.
--
-- (2) tax_amount & service_charge TIDAK dihitung ulang, dengan alasan yang sama
--     (butuh settings historis). Yang dijamin di sini: "total sebuah order
--     selalu sama dengan jumlah bagian-bagiannya".
--
-- (3) Trigger UPDATE dibatasi ke kolom uang saja (`UPDATE OF ...`). Tanpa itu,
--     `UPDATE orders SET status='paid'` akan ikut menghitung ulang dan diam-diam
--     MENULIS ULANG total order historis yang terlanjur tak konsisten — mengubah
--     angka keuangan masa lalu. Status-only update tidak boleh menyentuh uang.

-- ── 1. Snapshot perlakuan pajak pada order ───────────────────────────────────
-- Sengaja NULLABLE tanpa default: menambah kolom nullable tidak menulis ulang
-- tabel & tidak memicu trigger, jadi total order historis tidak tersentuh.
-- Baris lama tetap NULL dan diperlakukan sebagai false (COALESCE di bawah).
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS tax_inclusive BOOLEAN;

COMMENT ON COLUMN public.orders.tax_inclusive IS
  'Snapshot: apakah harga pada order ini sudah memuat pajak. Disnapshot agar '
  'total order lama tetap bisa dihitung ulang dengan benar walau setelan outlet '
  'berubah kemudian. NULL (baris lama) = false.';

-- ── 2. Hitung ulang total dari komponen order ────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- Perlakuan pajak di-snapshot sekali, saat order dibuat. Bila klien tidak
  -- mengirimnya (mis. jalur lama), ambil dari setelan outlet SAAT INI — benar
  -- untuk order baru, dan itulah satu-satunya momen settings boleh dibaca.
  IF TG_OP = 'INSERT' AND NEW.tax_inclusive IS NULL THEN
    SELECT COALESCE((settings->>'tax_inclusive')::boolean, false)
      INTO NEW.tax_inclusive
      FROM outlets WHERE id = NEW.outlet_id;
    NEW.tax_inclusive := COALESCE(NEW.tax_inclusive, false);
  END IF;

  -- Rumus WAJIB identik dengan PosState.total di aplikasi & create_self_order.
  -- Saat harga sudah memuat pajak, komponen pajak TIDAK ditambahkan lagi — ia
  -- sudah ada di dalam subtotal.
  NEW.total_amount :=
      GREATEST(0, COALESCE(NEW.subtotal, 0)
                  - COALESCE(NEW.discount_amount, 0)
                  - COALESCE(NEW.loyalty_discount, 0))
    + CASE WHEN COALESCE(NEW.tax_inclusive, false)
             THEN 0 ELSE COALESCE(NEW.tax_amount, 0) END
    + COALESCE(NEW.service_charge, 0);

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_order_total() IS
  'Jadikan total_amount turunan dari komponen order (server yang berwenang, '
  'bukan klien). Tidak membaca settings kecuali untuk snapshot tax_inclusive '
  'saat INSERT, agar order historis/offline tidak dihitung ulang dengan tarif '
  'yang sudah berubah.';

-- `total_amount` WAJIB ikut di daftar UPDATE OF. Tanpa itu, `UPDATE orders SET
-- total_amount = 1` tidak memicu trigger sama sekali dan klien tetap bisa
-- memalsukan total lewat update langsung — seluruh invariant ini jadi bocor.
-- Dengan ia terdaftar, upaya menulis total apa pun tetap dihitung ulang dari
-- komponen, jadi nilai kiriman klien selalu ditimpa.
DROP TRIGGER IF EXISTS trg_enforce_order_total ON public.orders;
CREATE TRIGGER trg_enforce_order_total
  BEFORE INSERT OR UPDATE OF
    subtotal, discount_amount, loyalty_discount,
    tax_amount, service_charge, tax_inclusive, total_amount
  ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_order_total();

-- ── 3. merge_orders: ikut jumlahkan loyalty_discount ─────────────────────────
-- Dulu semua komponen dijumlahkan KECUALI loyalty_discount, sementara
-- total_amount dijumlahkan apa adanya — jadi diskon poin order sumber ikut
-- terhitung di total tapi hilang dari komponennya. Dengan invariant di atas,
-- total kini diturunkan dari komponen, sehingga loyalty_discount WAJIB ikut
-- dijumlahkan; kalau tidak, order hasil merge jadi lebih mahal dari seharusnya.
-- Salinan setia 089 — HANYA blok penjumlahan uang yang berubah (ditandai
-- "◄ 116"). Signature (RETURNS JSONB), pemeriksaan izin, cek status aktif,
-- larangan sumber ber-pembayaran, void_reason, dan return value dipertahankan
-- persis; mengubahnya di sini akan merusak fitur gabung bill.
CREATE OR REPLACE FUNCTION merge_orders(p_source UUID, p_target UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_src orders%ROWTYPE;
  v_tgt orders%ROWTYPE;
  v_active TEXT[] := ARRAY['draft', 'confirmed', 'preparing', 'ready', 'served'];
BEGIN
  IF p_source = p_target THEN
    RAISE EXCEPTION 'Order sumber dan tujuan tidak boleh sama';
  END IF;

  SELECT * INTO v_src FROM orders WHERE id = p_source;
  SELECT * INTO v_tgt FROM orders WHERE id = p_target;
  IF v_src.id IS NULL OR v_tgt.id IS NULL THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- Izin: owner atau kasir pada outlet yang sama untuk kedua order.
  IF NOT (is_owner()
          OR (v_src.outlet_id = auth_outlet_id()
              AND v_tgt.outlet_id = auth_outlet_id())) THEN
    RAISE EXCEPTION 'Tidak berizin menggabung order ini';
  END IF;
  IF v_src.outlet_id <> v_tgt.outlet_id THEN
    RAISE EXCEPTION 'Order beda outlet tidak bisa digabung';
  END IF;

  -- Keduanya harus aktif (belum lunas/batal/void).
  IF NOT (v_src.status::text = ANY(v_active))
     OR NOT (v_tgt.status::text = ANY(v_active)) THEN
    RAISE EXCEPTION 'Hanya order aktif (belum lunas) yang bisa digabung';
  END IF;

  -- Sumber tak boleh sudah ada pembayaran (mis. split bayar sebagian).
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_source) THEN
    RAISE EXCEPTION 'Order sumber sudah punya pembayaran — tidak bisa digabung';
  END IF;

  -- Pindah item (order_item_options ikut karena mengacu order_item_id) +
  -- transaksi stok (jaga atribusi HPP & agar void sumber tak restore ganda).
  UPDATE order_items       SET order_id = p_target WHERE order_id = p_source;
  UPDATE stock_transactions SET order_id = p_target WHERE order_id = p_source;

  -- Jumlahkan nilai uang → total gabungan = total_src + total_tgt (kekal).
  -- ◄ 116: loyalty_discount ikut dijumlahkan — dulu terlewat, sehingga diskon
  -- poin order sumber tetap terhitung di total tapi hilang dari komponennya.
  -- total_amount sengaja TIDAK di-set lagi: trigger enforce_order_total yang
  -- menurunkannya dari komponen (nilainya tetap = total_src + total_tgt).
  UPDATE orders SET
    subtotal         = v_tgt.subtotal        + v_src.subtotal,
    discount_amount  = v_tgt.discount_amount + v_src.discount_amount,
    loyalty_discount = COALESCE(v_tgt.loyalty_discount, 0)
                     + COALESCE(v_src.loyalty_discount, 0),          -- ◄ 116
    tax_amount       = v_tgt.tax_amount      + v_src.tax_amount,
    service_charge   = v_tgt.service_charge  + v_src.service_charge,
    updated_at       = now()
  WHERE id = p_target;

  -- Void sumber (item sudah kosong → restore stok no-op) + bebaskan mejanya
  -- (via trigger sync_table_status).
  UPDATE orders SET
    status      = 'void',
    void_reason = 'Digabung ke order ' || v_tgt.order_number,
    updated_at  = now()
  WHERE id = p_source;

  RETURN jsonb_build_object(
    'merged_into', p_target,
    'source_voided', p_source
  );
END;
$$;

REVOKE ALL ON FUNCTION merge_orders(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION merge_orders(UUID, UUID) TO authenticated;

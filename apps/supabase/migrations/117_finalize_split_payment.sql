-- 117_finalize_split_payment.sql
-- Order hanya boleh LUNAS bila pembayarannya benar-benar menutupi total.
--
-- MASALAH. "Selesaikan Pembayaran" pada bagi tagihan hanya menjalankan
-- `UPDATE orders SET status='paid'`. Satu-satunya yang menjaga "sisa harus nol"
-- adalah `_remaining <= 0` di layar kasir. Artinya bug klien, race, atau
-- panggilan API langsung bisa melunasi order tanpa satu rupiah pun masuk —
-- dan tidak ada jejak yang mencurigakan, karena statusnya sah.
--
-- Ini sisi lain dari 116: 116 menjamin total order benar; ini menjamin uang
-- yang masuk memang menutupi total itu.
--
-- Toleransi 1 rupiah dipakai untuk menyerap selisih pembulatan antar-metode
-- pada bagi tagihan (mis. 3 orang membagi Rp 100.000). Tanpa toleransi, kasir
-- bisa terjebak: layar menunjukkan lunas, server menolak.

CREATE OR REPLACE FUNCTION public.finalize_split_payment(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_paid  NUMERIC;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = 'P0002';
  END IF;

  -- Wewenang dicocokkan dengan policy orders_update (005): owner, atau staf
  -- pada outlet order tsb. SECURITY DEFINER menembus RLS, jadi pemeriksaan ini
  -- WAJIB eksplisit. COALESCE: is_owner() mengembalikan NULL (bukan false) bila
  -- pemanggil tak punya baris profiles — tanpa itu, `IF NOT NULL` dianggap false
  -- dan pemeriksaan terlewat diam-diam.
  IF NOT (
       COALESCE(is_owner(), false)
       OR auth_outlet_id() IS NOT DISTINCT FROM v_order.outlet_id
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang atas order ini' USING ERRCODE = '42501';
  END IF;

  -- Idempoten: sudah lunas → jangan error, cukup laporkan apa adanya. Bagi
  -- tagihan sering di-tap ulang saat koneksi lambat.
  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('status', 'paid', 'already', true);
  END IF;

  -- Enum order_status TIDAK punya 'refunded' — refund memakai 'cancelled'
  -- (lihat 081_fix_refunded_enum). Menyebut 'refunded' di sini membuat
  -- perbandingan enum gagal saat runtime, bukan sekadar tak cocok.
  IF v_order.status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan — tidak bisa dilunasi'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM payments WHERE order_id = p_order_id;

  IF v_paid + 1 < v_order.total_amount THEN
    RAISE EXCEPTION 'Pembayaran belum menutupi total (terbayar % dari %)',
      v_paid, v_order.total_amount
      USING ERRCODE = '22023';
  END IF;

  UPDATE orders SET status = 'paid', updated_at = now()
  WHERE id = p_order_id
    AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');

  RETURN jsonb_build_object(
    'status', 'paid',
    'paid_total', v_paid,
    'order_total', v_order.total_amount
  );
END;
$$;

COMMENT ON FUNCTION public.finalize_split_payment(UUID) IS
  'Lunasi order bagi tagihan HANYA bila jumlah payments menutupi total_amount '
  '(toleransi 1 rupiah untuk pembulatan). Dulu klien yang memutuskan lunas via '
  'UPDATE status langsung, tanpa server memeriksa uangnya masuk.';

REVOKE ALL ON FUNCTION public.finalize_split_payment(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_split_payment(UUID) TO authenticated;

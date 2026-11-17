-- 108_wib_dates_cron_cleanup.sql
-- AUDIT "BOM WAKTU" — celah kecil yang baru terasa berbulan-bulan kemudian.
--
-- (1) TANGGAL UTC vs WIB. `CURRENT_DATE` di Postgres Supabase = tanggal UTC.
--     Antara 00:00–06:59 WIB, tanggal UTC masih KEMARIN. Akibatnya tiap malam:
--       • chk_expense_date_not_future menolak pengeluaran bertanggal "hari ini"
--         ("kadang gagal simpan pengeluaran" yang munculnya cuma malam hari).
--       • Promo/voucher yang berakhir kemarin masih lolos validasi ~7 jam;
--         promo yang mulai hari ini ditolak ~7 jam.
--       • Default expense_date terisi tanggal kemarin.
--     Outlet beroperasi larut malam (riwayat shift 21:00–23:00+) → pasti kena.
--
-- (2) JADWAL pg_cron memakai UTC: job "malam" 02:00–03:00 UTC = 09:00–10:00 WIB
--     alias JAM OPERASIONAL. VACUUM/prune/refresh ikut bersaing dengan
--     transaksi pagi. Digeser ke 19:00–20:00 UTC = 02:00–03:00 WIB.
--
-- (3) generate_order_number (004) memakai COUNT(*)+1 → rawan race. Sudah TIDAK
--     dipanggil siapa pun (semua jalur pakai get_next_order_number yang atomik),
--     tapi dibiarkan hidup = undangan dipakai lagi kelak. Dibuang.

-- ── Helper: tanggal hari ini zona Asia/Jakarta ───────────────────────────────
CREATE OR REPLACE FUNCTION public.jkt_today()
RETURNS DATE
LANGUAGE sql STABLE
SET search_path = public AS
$$ SELECT (now() AT TIME ZONE 'Asia/Jakarta')::date $$;

REVOKE ALL ON FUNCTION public.jkt_today() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jkt_today() TO anon, authenticated;

-- ── (1a) expenses: default & constraint pakai tanggal WIB ────────────────────
ALTER TABLE expenses
  ALTER COLUMN expense_date SET DEFAULT (now() AT TIME ZONE 'Asia/Jakarta')::date;

ALTER TABLE expenses DROP CONSTRAINT IF EXISTS chk_expense_date_not_future;
ALTER TABLE expenses ADD CONSTRAINT chk_expense_date_not_future
  CHECK (expense_date <= jkt_today());

-- ── (1b) validate_promo_code: rentang tanggal promo dinilai dlm WIB ─────────
CREATE OR REPLACE FUNCTION validate_promo_code(
  p_code      TEXT,
  p_outlet_id UUID,
  p_subtotal  NUMERIC
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher   vouchers%ROWTYPE;
  v_promo     promos%ROWTYPE;
  v_discount  NUMERIC;
  v_today     DATE := jkt_today();
BEGIN
  SELECT * INTO v_voucher
  FROM vouchers
  WHERE UPPER(TRIM(code)) = UPPER(TRIM(p_code))
    AND outlet_id = p_outlet_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kode voucher tidak ditemukan atau tidak aktif';
  END IF;

  IF v_voucher.usage_limit IS NOT NULL AND v_voucher.usage_count >= v_voucher.usage_limit THEN
    RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan';
  END IF;

  SELECT * INTO v_promo FROM promos WHERE id = v_voucher.promo_id;

  IF NOT FOUND OR NOT v_promo.is_active THEN
    RAISE EXCEPTION 'Promo tidak aktif';
  END IF;

  IF v_promo.start_date IS NOT NULL AND v_today < v_promo.start_date THEN
    RAISE EXCEPTION 'Promo belum berlaku (mulai %)' , v_promo.start_date::TEXT;
  END IF;

  IF v_promo.end_date IS NOT NULL AND v_today > v_promo.end_date THEN
    RAISE EXCEPTION 'Promo sudah kedaluwarsa';
  END IF;

  IF v_promo.usage_limit IS NOT NULL AND v_promo.usage_count >= v_promo.usage_limit THEN
    RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan total';
  END IF;

  IF p_subtotal < v_promo.min_order THEN
    RAISE EXCEPTION 'Minimum order Rp % untuk promo ini', TO_CHAR(v_promo.min_order, 'FM999,999,999');
  END IF;

  IF v_promo.type = 'percentage' THEN
    v_discount := ROUND(p_subtotal * v_promo.value / 100, 0);
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := LEAST(v_discount, v_promo.max_discount);
    END IF;
  ELSIF v_promo.type = 'fixed' THEN
    v_discount := LEAST(v_promo.value, p_subtotal);
  ELSE
    v_discount := 0;
  END IF;

  RETURN json_build_object(
    'promo_id',       v_promo.id,
    'voucher_id',     v_voucher.id,
    'promo_name',     v_promo.name,
    'discount_amount', v_discount
  );
END;
$$;

REVOKE ALL ON FUNCTION validate_promo_code(TEXT, UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION validate_promo_code(TEXT, UUID, NUMERIC) TO anon, authenticated;

-- ── (1c) apply_promo_usage (versi 076) — kedaluwarsa dinilai dlm WIB ────────
CREATE OR REPLACE FUNCTION public.apply_promo_usage(
  p_promo_id   UUID,
  p_voucher_id UUID DEFAULT NULL,
  p_order_id   UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_promo_limit    INTEGER;
  v_promo_count    INTEGER;
  v_promo_end_date DATE;
  v_voucher_limit  INTEGER;
  v_voucher_count  INTEGER;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id wajib diisi';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id) THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  IF p_promo_id IS NOT NULL THEN
    SELECT usage_limit, usage_count, end_date
    INTO v_promo_limit, v_promo_count, v_promo_end_date
    FROM promos WHERE id = p_promo_id FOR UPDATE;

    IF NOT EXISTS (
      SELECT 1 FROM promo_usages
      WHERE promo_id = p_promo_id AND order_id = p_order_id
    ) THEN
      IF v_promo_end_date IS NOT NULL AND v_promo_end_date < jkt_today() THEN
        RAISE EXCEPTION 'Promo sudah kedaluwarsa';
      END IF;
      IF v_promo_limit IS NOT NULL AND v_promo_count >= v_promo_limit THEN
        RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan';
      END IF;

      INSERT INTO promo_usages (order_id, promo_id) VALUES (p_order_id, p_promo_id);
      UPDATE promos SET usage_count = usage_count + 1, updated_at = NOW()
      WHERE id = p_promo_id;
    END IF;
  END IF;

  IF p_voucher_id IS NOT NULL THEN
    SELECT usage_limit, usage_count
    INTO v_voucher_limit, v_voucher_count
    FROM vouchers WHERE id = p_voucher_id FOR UPDATE;

    IF NOT EXISTS (
      SELECT 1 FROM promo_usages
      WHERE voucher_id = p_voucher_id AND order_id = p_order_id
    ) THEN
      IF v_voucher_limit IS NOT NULL AND v_voucher_count >= v_voucher_limit THEN
        RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan';
      END IF;

      INSERT INTO promo_usages (order_id, voucher_id) VALUES (p_order_id, p_voucher_id);
      UPDATE vouchers SET usage_count = usage_count + 1
      WHERE id = p_voucher_id;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_promo_usage(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_promo_usage(UUID, UUID, UUID) TO anon, authenticated;

-- ── (1d) increment_promo_usage (versi 025) — WIB ────────────────────────────
CREATE OR REPLACE FUNCTION increment_promo_usage(p_promo_id UUID)
RETURNS VOID LANGUAGE plpgsql
SET search_path = public AS $$
DECLARE
  v_limit    INTEGER;
  v_count    INTEGER;
  v_end_date DATE;
BEGIN
  SELECT usage_limit, usage_count, end_date
  INTO v_limit, v_count, v_end_date
  FROM promos WHERE id = p_promo_id FOR UPDATE;

  IF v_end_date IS NOT NULL AND v_end_date < jkt_today() THEN
    RAISE EXCEPTION 'promo has expired';
  END IF;

  IF v_limit IS NOT NULL AND v_count >= v_limit THEN
    RAISE EXCEPTION 'promo usage limit reached';
  END IF;

  UPDATE promos
  SET usage_count = usage_count + 1, updated_at = NOW()
  WHERE id = p_promo_id;
END;
$$;

-- ── (2) Geser semua job maintenance ke dini hari WIB ─────────────────────────
-- cron.schedule dgn nama sama = upsert; aman dijalankan ulang.
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('prune-order-audit-log',        '10 19 * * *', $$SELECT public.prune_order_audit_log(90);$$);   -- 02:10 WIB
SELECT cron.schedule('prune-error-logs',             '20 19 * * *', $$SELECT public.prune_error_logs(30);$$);        -- 02:20 WIB
SELECT cron.schedule('refresh-sales-daily-summary',  '30 19 * * *', $$SELECT public.refresh_sales_daily_summary();$$); -- 02:30 WIB
SELECT cron.schedule('nightly-vacuum-hot-tables',    '40 19 * * *', $$VACUUM (ANALYZE) orders; VACUUM (ANALYZE) restaurant_tables; VACUUM (ANALYZE) ingredients; VACUUM (ANALYZE) shifts; VACUUM (ANALYZE) error_logs;$$); -- 02:40 WIB
SELECT cron.schedule('log-db-size',                  '0 20 * * *',  $$SELECT public.log_db_size();$$);               -- 03:00 WIB

-- ── (3) Buang fungsi penomoran lama yang rawan race (dead code) ──────────────
DROP FUNCTION IF EXISTS generate_order_number(UUID);

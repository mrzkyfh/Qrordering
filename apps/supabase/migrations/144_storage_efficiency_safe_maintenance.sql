-- 144_storage_efficiency_safe_maintenance.sql
-- Optimasi database tanpa menghapus data finansial atau mengurangi fitur:
--   1. Refresh sales summary memakai bounded timestamp + grouped scan.
--   2. Prune log dilakukan per batch agar lock dan dead tuple terkendali.
--   3. Counter nomor order dan log ukuran DB tidak disimpan selamanya.
--   4. Tambah indeks kecil yang mempercepat lookup idempotensi promo.
--
-- Sengaja TIDAK memangkas orders paid, payments, expenses, stock ledger,
-- loyalty history, atau sales_daily_summary. Data tersebut masih dibutuhkan
-- oleh laporan, rekonsiliasi, dan audit.

-- ── 1. Refresh summary harian: satu scan terkelompok, bukan subquery ───────
-- Versi 084 menjalankan subquery payment/category berulang untuk setiap baris
-- outlet. Selain lebih mahal, filter `(created_at AT TIME ZONE ...)::date`
-- menyulitkan planner memakai indeks timestamp. Batas UTC dihitung dari WIB,
-- lalu setiap sumber diagregasi sekali.
CREATE OR REPLACE FUNCTION public.refresh_sales_daily_summary(
  p_date DATE DEFAULT (public.jkt_today() - 1)
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_from TIMESTAMPTZ := (p_date::TIMESTAMP AT TIME ZONE 'Asia/Jakarta');
  v_to   TIMESTAMPTZ := ((p_date + 1)::TIMESTAMP AT TIME ZONE 'Asia/Jakarta');
  v_rows INTEGER := 0;
BEGIN
  WITH paid_orders AS (
    SELECT
      o.id,
      o.outlet_id,
      o.subtotal,
      o.discount_amount,
      o.tax_amount,
      o.service_charge,
      o.total_amount
    FROM public.orders o
    WHERE o.status = 'paid'
      AND o.created_at >= v_from
      AND o.created_at < v_to
  ), order_rollup AS (
    SELECT
      outlet_id,
      COUNT(*)::INTEGER AS order_count,
      COALESCE(SUM(subtotal), 0)::NUMERIC(14,2) AS gross,
      COALESCE(SUM(discount_amount), 0)::NUMERIC(14,2) AS discount,
      COALESCE(SUM(tax_amount), 0)::NUMERIC(14,2) AS tax,
      COALESCE(SUM(service_charge), 0)::NUMERIC(14,2) AS service,
      COALESCE(SUM(total_amount), 0)::NUMERIC(14,2) AS net
    FROM paid_orders
    GROUP BY outlet_id
  ), payment_rollup AS (
    SELECT
      x.outlet_id,
      jsonb_object_agg(x.method, x.amount) AS by_payment
    FROM (
      SELECT
        o2.outlet_id,
        p.method::TEXT AS method,
        COALESCE(SUM(p.amount), 0)::NUMERIC(14,2) AS amount
      FROM public.payments p
      JOIN public.orders o2
        ON o2.id = p.order_id
       AND o2.status = 'paid'
      WHERE p.paid_at >= v_from
        AND p.paid_at < v_to
      GROUP BY o2.outlet_id, p.method
    ) x
    GROUP BY x.outlet_id
  ), category_rollup AS (
    SELECT
      x.outlet_id,
      jsonb_object_agg(x.category_id, x.revenue) AS by_category
    FROM (
      SELECT
        o2.outlet_id,
        mi.category_id::TEXT AS category_id,
        COALESCE(SUM(
          oi.subtotal - COALESCE(oi.refunded_qty, 0) * oi.unit_price
        ), 0)::NUMERIC(14,2) AS revenue
      FROM public.order_items oi
      JOIN public.orders o2 ON o2.id = oi.order_id
      JOIN public.menu_items mi ON mi.id = oi.menu_item_id
      WHERE o2.status = 'paid'
        AND o2.created_at >= v_from
        AND o2.created_at < v_to
        AND mi.category_id IS NOT NULL
      GROUP BY o2.outlet_id, mi.category_id
    ) x
    GROUP BY x.outlet_id
  )
  INSERT INTO public.sales_daily_summary AS s (
    outlet_id, sales_date, order_count, gross, discount, tax, service, net,
    by_payment, by_category, refreshed_at
  )
  SELECT
    r.outlet_id,
    p_date,
    r.order_count,
    r.gross,
    r.discount,
    r.tax,
    r.service,
    r.net,
    COALESCE(pr.by_payment, '{}'::JSONB),
    COALESCE(cr.by_category, '{}'::JSONB),
    now()
  FROM order_rollup r
  LEFT JOIN payment_rollup pr ON pr.outlet_id = r.outlet_id
  LEFT JOIN category_rollup cr ON cr.outlet_id = r.outlet_id
  ON CONFLICT (outlet_id, sales_date) DO UPDATE SET
    order_count = EXCLUDED.order_count,
    gross = EXCLUDED.gross,
    discount = EXCLUDED.discount,
    tax = EXCLUDED.tax,
    service = EXCLUDED.service,
    net = EXCLUDED.net,
    by_payment = EXCLUDED.by_payment,
    by_category = EXCLUDED.by_category,
    refreshed_at = now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_sales_daily_summary(DATE) FROM PUBLIC;

-- ── 2. Promo usage lookup: cegah scan penuh saat retry ─────────────────────
-- Ini tidak menambah data transaksi; indeks membuat pengecekan idempotensi
-- apply_promo_usage tetap cepat ketika histori usage sudah besar.
CREATE INDEX IF NOT EXISTS idx_promo_usages_promo_order
  ON public.promo_usages(promo_id, order_id)
  WHERE promo_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_promo_usages_voucher_order
  ON public.promo_usages(voucher_id, order_id)
  WHERE voucher_id IS NOT NULL;

-- ── 3. Prune append-only maintenance log secara batch ─────────────────────
CREATE OR REPLACE FUNCTION public.prune_order_audit_log(p_keep_days INT DEFAULT 45)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_batch INTEGER;
  v_deleted INTEGER := 0;
BEGIN
  LOOP
    WITH doomed AS (
      SELECT al.id
      FROM public.order_audit_log al
      JOIN public.orders o ON o.id = al.order_id
      WHERE al.created_at < now() - make_interval(days => GREATEST(p_keep_days, 1))
        AND o.status IN ('paid', 'void', 'cancelled')
      LIMIT 5000
    )
    DELETE FROM public.order_audit_log al
    USING doomed d
    WHERE al.id = d.id;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION public.prune_error_logs(p_keep_days INT DEFAULT 14)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_batch INTEGER;
  v_deleted INTEGER := 0;
BEGIN
  LOOP
    WITH doomed AS (
      SELECT id
      FROM public.error_logs
      WHERE created_at < now() - make_interval(days => GREATEST(p_keep_days, 1))
      LIMIT 5000
    )
    DELETE FROM public.error_logs e
    USING doomed d
    WHERE e.id = d.id;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_order_audit_log(INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prune_error_logs(INT) FROM PUBLIC;

-- ── 4. Counter nomor order: hanya tanggal aktif yang diperlukan ────────────
-- Counter lama tidak dirujuk oleh order; order menyimpan order_seq_date dan
-- nomor finalnya sendiri. Simpan dua tahun untuk keamanan operasional, lalu
-- hapus batch. Ini hanya memangkas metadata counter, bukan order.
CREATE OR REPLACE FUNCTION public.prune_order_daily_counters(
  p_keep_days INTEGER DEFAULT 730
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_batch INTEGER;
  v_deleted INTEGER := 0;
  v_cutoff DATE := public.jkt_today() - GREATEST(p_keep_days, 730);
BEGIN
  LOOP
    WITH doomed AS (
      SELECT outlet_id, counter_date
      FROM public.order_daily_counters
      WHERE counter_date < v_cutoff
      LIMIT 5000
    )
    DELETE FROM public.order_daily_counters c
    USING doomed d
    WHERE c.outlet_id = d.outlet_id
      AND c.counter_date = d.counter_date;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_order_daily_counters(INTEGER) FROM PUBLIC;

-- ── 5. Ukuran DB: simpan tren dua tahun, bukan selamanya ───────────────────
CREATE OR REPLACE FUNCTION public.prune_db_size_log(
  p_keep_days INTEGER DEFAULT 730
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM public.db_size_log
  WHERE logged_at < now() - make_interval(days => GREATEST(p_keep_days, 730));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_db_size_log(INTEGER) FROM PUBLIC;

-- ── 6. Maintenance schedule WIB 02:xx (pg_cron menyimpan UTC) ─────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'prune-order-audit-log', '10 19 * * *',
  $$SELECT public.prune_order_audit_log(45);$$
);
SELECT cron.schedule(
  'prune-error-logs', '20 19 * * *',
  $$SELECT public.prune_error_logs(14);$$
);
SELECT cron.schedule(
  'prune-order-daily-counters', '25 19 * * *',
  $$SELECT public.prune_order_daily_counters(730);$$
);
SELECT cron.schedule(
  'prune-db-size-log', '30 19 * * *',
  $$SELECT public.prune_db_size_log(730);$$
);
SELECT cron.schedule(
  'nightly-vacuum-hot-tables', '40 19 * * *',
  $$VACUUM (ANALYZE) orders; VACUUM (ANALYZE) restaurant_tables; VACUUM (ANALYZE) ingredients; VACUUM (ANALYZE) shifts; VACUUM (ANALYZE) error_logs; VACUUM (ANALYZE) order_audit_log; VACUUM (ANALYZE) order_daily_counters; VACUUM (ANALYZE) db_size_log;$$
);

COMMENT ON FUNCTION public.prune_order_daily_counters(INTEGER) IS
  'Hapus metadata counter order yang sudah lebih dari dua tahun; order historis '
  'dan nomor struk tetap utuh (144).';
COMMENT ON FUNCTION public.prune_db_size_log(INTEGER) IS
  'Pertahankan tren ukuran database dua tahun; log lama tidak dibutuhkan aplikasi.';

-- 084_sales_daily_summary.sql
-- STRATEGI RETENSI #2 — rollup penjualan harian (fondasi untuk arsip raw).
-- Satu baris/outlet/hari. Laporan historis baca dari sini (kecil & cepat),
-- sehingga order raw lama boleh diarsip/dihapus tanpa kehilangan angka laporan.

CREATE TABLE IF NOT EXISTS sales_daily_summary (
  outlet_id     UUID          NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  sales_date    DATE          NOT NULL,
  order_count   INTEGER       NOT NULL DEFAULT 0,
  gross         NUMERIC(14,2) NOT NULL DEFAULT 0,  -- subtotal
  discount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax           NUMERIC(14,2) NOT NULL DEFAULT 0,
  service       NUMERIC(14,2) NOT NULL DEFAULT 0,
  net           NUMERIC(14,2) NOT NULL DEFAULT 0,  -- total_amount
  by_payment    JSONB         NOT NULL DEFAULT '{}'::jsonb,  -- {cash: x, qris: y, ...}
  by_category   JSONB         NOT NULL DEFAULT '{}'::jsonb,  -- {kategori_id: revenue}
  refreshed_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
  PRIMARY KEY (outlet_id, sales_date)
);

-- ── RLS: tenant-scoped (pola sama migrasi 048) ──────────────────────────────
ALTER TABLE sales_daily_summary ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sales_daily_summary_select" ON sales_daily_summary;
CREATE POLICY "sales_daily_summary_select" ON sales_daily_summary
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

GRANT SELECT ON sales_daily_summary TO authenticated;

-- ── Fungsi refresh: upsert ringkasan untuk satu tanggal (default: kemarin) ───
-- Hanya order final (paid) yang dihitung sebagai penjualan.
CREATE OR REPLACE FUNCTION public.refresh_sales_daily_summary(
  p_date DATE DEFAULT (current_date - 1)
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  INSERT INTO sales_daily_summary AS s (
    outlet_id, sales_date, order_count, gross, discount, tax, service, net,
    by_payment, by_category, refreshed_at
  )
  SELECT
    o.outlet_id,
    p_date,
    count(DISTINCT o.id),
    coalesce(sum(o.subtotal), 0),
    coalesce(sum(o.discount_amount), 0),
    coalesce(sum(o.tax_amount), 0),
    coalesce(sum(o.service_charge), 0),
    coalesce(sum(o.total_amount), 0),
    coalesce((
      SELECT jsonb_object_agg(pm.method, pm.amt)
      FROM (
        SELECT pay.method::text AS method, sum(pay.amount) AS amt
        FROM payments pay
        JOIN orders o2 ON o2.id = pay.order_id
        WHERE o2.outlet_id = o.outlet_id
          AND (pay.paid_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
          AND o2.status = 'paid'
        GROUP BY pay.method
      ) pm
    ), '{}'::jsonb),
    coalesce((
      SELECT jsonb_object_agg(cat.category_id, cat.rev)
      FROM (
        SELECT mi.category_id::text AS category_id, sum(oi.subtotal) AS rev
        FROM order_items oi
        JOIN orders o3 ON o3.id = oi.order_id
        JOIN menu_items mi ON mi.id = oi.menu_item_id
        WHERE o3.outlet_id = o.outlet_id
          AND (o3.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
          AND o3.status = 'paid'
          AND mi.category_id IS NOT NULL
        GROUP BY mi.category_id
      ) cat
    ), '{}'::jsonb),
    now()
  FROM orders o
  WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
    AND o.status = 'paid'
  GROUP BY o.outlet_id
  ON CONFLICT (outlet_id, sales_date) DO UPDATE SET
    order_count = EXCLUDED.order_count,
    gross       = EXCLUDED.gross,
    discount    = EXCLUDED.discount,
    tax         = EXCLUDED.tax,
    service     = EXCLUDED.service,
    net         = EXCLUDED.net,
    by_payment  = EXCLUDED.by_payment,
    by_category = EXCLUDED.by_category,
    refreshed_at = now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_sales_daily_summary(DATE) FROM PUBLIC;

-- ── Backfill seluruh histori yang sudah ada (sekali jalan) ──────────────────
DO $$
DECLARE
  d DATE;
BEGIN
  FOR d IN
    SELECT DISTINCT (created_at AT TIME ZONE 'Asia/Jakarta')::date
    FROM orders WHERE status = 'paid'
  LOOP
    PERFORM public.refresh_sales_daily_summary(d);
  END LOOP;
END;
$$;

-- ── Jadwalkan refresh harian 02:20 (setelah prune audit log) ────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'refresh-sales-daily-summary',
  '20 2 * * *',
  $$SELECT public.refresh_sales_daily_summary();$$
);

-- 140_cogs_snapshot_prune_item_detail.sql
-- Hemat DB: pangkas DETAIL item order lama (order_items + order_item_options),
-- pertahankan header order + payments SELAMANYA. Detail item = ~59% tempat
-- transaksi (terukur), jadi ini penghematan terbesar tanpa mengorbankan laporan
-- keuangan/pajak/pembayaran yang membaca header saja.
--
-- MASALAH yang diselesaikan lebih dulu (2b): laba-rugi (v_profit_loss) menghitung
-- HPP dari v_order_hpp yang MEN-JOIN order_items × resep. Kalau order_items
-- dipangkas, HPP order lama jadi 0 → laba kotor historis melonjak salah.
-- Solusi: SNAPSHOT HPP ke kolom header orders.cogs_amount, dan v_order_hpp
-- membacanya dari header (bukan join). Dengan begitu laba-rugi LENGKAP tetap
-- abadi meski detail item hilang.
--
-- Bonus kebenaran: snapshot membekukan HPP pada biaya SAAT transaksi. v_order_hpp
-- lama menghitung dengan cost_per_unit TERKINI → laba-rugi historis berubah tiap
-- harga bahan naik. Snapshot menghilangkan distorsi itu.

-- ── 1. Kolom snapshot HPP di header ─────────────────────────────────────────
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS cogs_amount NUMERIC(14,2);

COMMENT ON COLUMN public.orders.cogs_amount IS
  'Snapshot HPP (modal bahan) order dari resep × biaya, net-of-refund. Diisi '
  'trigger saat item/refund berubah; dibaca v_order_hpp agar laba-rugi tetap '
  'ada setelah detail order_items dipangkas (140).';

-- ── 2. Trigger: jaga cogs_amount tetap sinkron dari order_items ──────────────
-- HANYA pada INSERT/UPDATE — TIDAK pada DELETE, supaya pemangkasan order_items
-- (di bawah) tidak menol-kan snapshot. SECURITY DEFINER: perlu membaca resep &
-- ingredients (ber-RLS) dan menulis header apa pun peran penulis item.
CREATE OR REPLACE FUNCTION public.snapshot_order_cogs()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.orders o
  SET cogs_amount = (
    SELECT COALESCE(SUM(
             GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
             * er.qty_per_portion
             * i.cost_per_unit
           ), 0)::NUMERIC(14,2)
    FROM public.order_items oi
    LEFT JOIN public.v_effective_recipe er ON er.menu_item_id = oi.menu_item_id
    LEFT JOIN public.ingredients i ON i.id = er.ingredient_id
    WHERE oi.order_id = NEW.order_id
  )
  WHERE o.id = NEW.order_id;
  RETURN NEW;
END;
$$;

-- cogs_amount BUKAN komponen total → tidak masuk UPDATE OF enforce_order_total,
-- jadi update ini tak memicu perhitungan ulang total (aman).
DROP TRIGGER IF EXISTS trg_snapshot_order_cogs ON public.order_items;
CREATE TRIGGER trg_snapshot_order_cogs
  AFTER INSERT OR UPDATE OF quantity, refunded_qty, menu_item_id, unit_price
  ON public.order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.snapshot_order_cogs();

-- ── 3. Backfill snapshot utk order yang sudah ada ───────────────────────────
UPDATE public.orders o
SET cogs_amount = sub.hpp
FROM (
  SELECT oi.order_id,
         COALESCE(SUM(
           GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
           * er.qty_per_portion
           * i.cost_per_unit
         ), 0)::NUMERIC(14,2) AS hpp
  FROM public.order_items oi
  LEFT JOIN public.v_effective_recipe er ON er.menu_item_id = oi.menu_item_id
  LEFT JOIN public.ingredients i ON i.id = er.ingredient_id
  GROUP BY oi.order_id
) sub
WHERE o.id = sub.order_id
  AND o.cogs_amount IS DISTINCT FROM sub.hpp;

-- ── 4. v_order_hpp baca HEADER (bukan join order_items) ─────────────────────
-- v_profit_loss BERGANTUNG pada v_order_hpp → drop dependen dulu (pelajaran 137).
DROP VIEW IF EXISTS public.v_profit_loss;
DROP VIEW IF EXISTS public.v_order_hpp;

CREATE VIEW public.v_order_hpp AS
SELECT
  o.id AS order_id,
  o.outlet_id,
  o.created_at,
  o.status,
  COALESCE(o.cogs_amount, 0)::NUMERIC(14,2) AS hpp_total
FROM public.orders o;

GRANT SELECT ON public.v_order_hpp TO authenticated;
ALTER VIEW public.v_order_hpp SET (security_invoker = on);

COMMENT ON VIEW public.v_order_hpp IS
  'HPP per order dari snapshot header orders.cogs_amount (140) — tak lagi '
  'men-join order_items, sehingga tetap ada setelah detail item dipangkas.';

-- v_profit_loss: IDENTIK dengan 137 (tetap membaca v_order_hpp yang kini
-- header-based). Dibuat ulang karena drop di atas.
CREATE VIEW public.v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    o.outlet_id,
    TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(o.subtotal) AS gross_revenue,
    SUM(o.discount_amount) AS total_discount,
    COALESCE(SUM(rf.refund), 0) AS total_refund,
    SUM(o.total_amount - COALESCE(rf.refund, 0)) AS net_revenue
  FROM public.orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund FROM public.refunds GROUP BY order_id
  ) rf ON rf.order_id = o.id
  WHERE o.status = 'paid'
  GROUP BY o.outlet_id, TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
),
monthly_hpp AS (
  SELECT
    outlet_id,
    TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(hpp_total) AS cost_of_goods
  FROM public.v_order_hpp
  WHERE status = 'paid'
  GROUP BY outlet_id, TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
),
monthly_expenses AS (
  SELECT
    outlet_id,
    TO_CHAR(expense_date, 'YYYY-MM') AS month,
    COALESCE(SUM(amount) FILTER (WHERE category <> 'bahan_baku'), 0) AS total_expenses
  FROM public.expenses
  GROUP BY outlet_id, TO_CHAR(expense_date, 'YYYY-MM')
),
all_periods AS (
  SELECT outlet_id, month FROM monthly_revenue
  UNION
  SELECT outlet_id, month FROM monthly_hpp
  UNION
  SELECT outlet_id, month FROM monthly_expenses
)
SELECT
  p.outlet_id,
  p.month,
  COALESCE(r.gross_revenue, 0)::numeric AS gross_revenue,
  COALESCE(r.total_discount, 0)::numeric AS total_discount,
  COALESCE(r.total_refund, 0)::numeric AS total_refund,
  COALESCE(r.net_revenue, 0)::numeric AS net_revenue,
  COALESCE(h.cost_of_goods, 0)::numeric AS cost_of_goods,
  (COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0))::numeric AS gross_profit,
  COALESCE(e.total_expenses, 0)::numeric AS total_expenses,
  ((COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0))
    - COALESCE(e.total_expenses, 0))::numeric AS net_profit
FROM all_periods p
LEFT JOIN monthly_revenue r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_hpp h ON h.outlet_id = p.outlet_id AND h.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;

GRANT SELECT ON public.v_profit_loss TO authenticated;
ALTER VIEW public.v_profit_loss SET (security_invoker = on);

-- ── 5. Pangkas DETAIL item order lunas > N bulan (default 6) ─────────────────
-- Hanya order_items yang dihapus; order_item_options & refund_items ikut lewat
-- FK ON DELETE CASCADE. Header orders + payments DIPERTAHANKAN → laporan
-- keuangan/pajak/pembayaran + laba-rugi (via cogs_amount) tetap utuh selamanya.
-- Order aktif (belum lunas) TIDAK PERNAH disentuh.
CREATE OR REPLACE FUNCTION public.prune_order_item_detail(p_keep_months INTEGER DEFAULT 6)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff  TIMESTAMPTZ;
  v_batch   INTEGER;
  v_deleted INTEGER := 0;
BEGIN
  v_cutoff := ((now() AT TIME ZONE 'Asia/Jakarta')::date
               - make_interval(months => GREATEST(p_keep_months, 1)))
              AT TIME ZONE 'Asia/Jakarta';

  LOOP
    WITH doomed AS (
      SELECT oi.id
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.status = 'paid'
        AND o.created_at < v_cutoff
      LIMIT 5000
    )
    DELETE FROM order_items oi USING doomed d WHERE oi.id = d.id;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;

  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_order_item_detail(INTEGER) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.prune_order_item_detail(INTEGER) IS
  'Pangkas order_items (+ cascade options/refund_items) order lunas > N bulan. '
  'Header orders + payments + cogs_amount dipertahankan → laporan keuangan & '
  'laba-rugi tetap abadi; hanya rincian per-item menu yang terbatas N bulan (140).';

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- 03:25 WIB, setelah refresh summary (02:30) & sebelum tak bentrok prune lain.
SELECT cron.schedule('prune-order-item-detail', '25 20 * * *',
                     $$SELECT public.prune_order_item_detail(6);$$);

-- ── 6. Perketat retensi LOG (Tingkat 1) ─────────────────────────────────────
-- Audit trail order dipakai untuk sengketa jangka pendek; 45 hari cukup.
-- Error log untuk diagnosa bug terbaru; 14 hari cukup.
SELECT cron.schedule('prune-order-audit-log', '10 19 * * *', $$SELECT public.prune_order_audit_log(45);$$);
SELECT cron.schedule('prune-error-logs',      '20 19 * * *', $$SELECT public.prune_error_logs(14);$$);

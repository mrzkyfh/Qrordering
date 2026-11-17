-- 118_sales_summary_net_refund.sql
-- sales_daily_summary WAJIB dikurangi refund — dan histori yang sudah terlanjur
-- salah di-backfill SEKARANG, selagi data mentahnya masih ada.
--
-- MASALAH. Refund parsial membiarkan order tetap 'paid' dan mencatat potongannya
-- di tabel `refunds` terpisah. 084 menjumlahkan `total_amount` untuk order
-- 'paid' — nol penyebutan refund. Jadi `net` melebih-lebihkan omzet sebesar
-- nilai yang direfund.
--
-- 095 sendiri sudah menyadari kelasnya: "Fase 1 (094) mencatat refund tapi
-- laporan masih gross. Migrasi ini membuat semua view penjualan jadi NET."
-- Tapi 095 hanya memperbaiki VIEW — sementara sales_daily_summary adalah TABEL
-- yang di-refresh fungsi, sehingga terlewat.
--
-- KENAPA MENDESAK. prune_old_orders (110) menghapus order > 6 bulan dan
-- bersandar pada ringkasan ini sebagai kebenaran permanen ("Angka laporan tetap
-- utuh selamanya di sales_daily_summary"). Tabel refunds ber-ON DELETE CASCADE
-- ke orders → ikut terhapus. Setelah prune, angka yang salah menjadi PERMANEN
-- dan buktinya lenyap: tidak ada cara memperbaikinya lagi. Backfill di bawah
-- hanya mungkin selama data mentahnya belum dipangkas.
--
-- Atribusi refund mengikuti v_tax_report (095): refund mengurangi tanggal ORDER,
-- bukan tanggal refund terjadi. Konsisten = laporan tidak saling bertentangan.

-- ── 1. Kolom refund (terlihat, bukan cuma dikurangkan diam-diam) ─────────────
ALTER TABLE sales_daily_summary
  ADD COLUMN IF NOT EXISTS refund NUMERIC(14,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN sales_daily_summary.refund IS
  'Total refund atas order yang DIBUAT pada tanggal ini (atribusi sama dengan '
  'v_tax_report). Sudah dikurangkan dari kolom net.';

COMMENT ON COLUMN sales_daily_summary.net IS
  'Omzet bersih = SUM(total_amount) − refund. Sejak 118 sudah net; sebelumnya '
  'gross dan melebih-lebihkan omzet.';

COMMENT ON COLUMN sales_daily_summary.by_payment IS
  'Uang MASUK per metode (gross, belum dikurangi refund) — refund adalah '
  'pergerakan kas terpisah. Untuk omzet bersih pakai kolom net.';

-- ── 2. Refresh: kurangi refund ───────────────────────────────────────────────
-- Salinan setia 084 — yang berubah hanya ditandai "◄ 118".
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
    refund,                                                        -- ◄ 118
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
    -- ◄ 118: net = total − refund (cermin v_tax_report).
    coalesce(sum(o.total_amount), 0) - coalesce(sum(rf.refund), 0),
    coalesce(sum(rf.refund), 0),                                   -- ◄ 118
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
  -- ◄ 118: LEFT JOIN → order tanpa refund tidak berubah angkanya.
  LEFT JOIN (
    SELECT order_id, sum(amount) AS refund FROM refunds GROUP BY order_id
  ) rf ON rf.order_id = o.id
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
    refund      = EXCLUDED.refund,                                 -- ◄ 118
    by_payment  = EXCLUDED.by_payment,
    by_category = EXCLUDED.by_category,
    refreshed_at = now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_sales_daily_summary(DATE) FROM PUBLIC;

-- ── 3. Refund yang terjadi BELAKANGAN harus memperbarui ringkasannya ─────────
-- Cron hanya me-refresh KEMARIN (108: '30 19 * * *' → 02:30 WIB). Refund atas
-- order 3 hari lalu tak akan pernah tercermin: ringkasan hari itu sudah dibuat
-- dan tak pernah disentuh lagi — ringkasan jadi bertentangan dengan v_tax_report.
--
-- Trigger dipasang di TABEL refunds, bukan di dalam RPC refund_order_items,
-- supaya jalur refund mana pun (RPC, perbaikan manual lewat SQL Editor) tetap
-- menjaga ringkasan tetap benar.
CREATE OR REPLACE FUNCTION public.refresh_summary_for_refund()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_date DATE;
BEGIN
  SELECT (o.created_at AT TIME ZONE 'Asia/Jakarta')::date
    INTO v_date
    FROM orders o
   WHERE o.id = COALESCE(NEW.order_id, OLD.order_id);

  IF v_date IS NOT NULL THEN
    PERFORM public.refresh_sales_daily_summary(v_date);
  END IF;
  RETURN NULL;  -- AFTER trigger
END;
$$;

-- refund_order_items menyisipkan baris refund dgn amount=0 lalu meng-UPDATE
-- amount-nya di akhir → kedua peristiwa disimak agar hasil akhirnya benar.
DROP TRIGGER IF EXISTS trg_refresh_summary_on_refund ON refunds;
CREATE TRIGGER trg_refresh_summary_on_refund
  AFTER INSERT OR UPDATE OF amount OR DELETE ON refunds
  FOR EACH ROW
  EXECUTE FUNCTION public.refresh_summary_for_refund();

-- ── 4. Backfill histori yang terlanjur salah ─────────────────────────────────
-- HANYA mungkin selagi order & refund mentahnya belum dipangkas prune (retensi
-- 6 bulan). Semua tanggal yang punya order 'paid' dihitung ulang; tanggal tanpa
-- refund menghasilkan angka yang sama seperti sebelumnya (LEFT JOIN + COALESCE).
DO $$
DECLARE
  d DATE;
  v_fixed INTEGER := 0;
BEGIN
  FOR d IN
    SELECT DISTINCT (created_at AT TIME ZONE 'Asia/Jakarta')::date
    FROM orders WHERE status = 'paid'
    ORDER BY 1
  LOOP
    PERFORM public.refresh_sales_daily_summary(d);
    v_fixed := v_fixed + 1;
  END LOOP;
  RAISE NOTICE '118: % hari dihitung ulang (net kini dikurangi refund)', v_fixed;
END;
$$;

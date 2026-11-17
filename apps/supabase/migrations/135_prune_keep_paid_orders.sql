-- 130_prune_keep_paid_orders.sql
-- prune_old_orders JANGAN menghapus order PAID — laporan membacanya langsung.
--
-- ══ BUG: pemangkasan menghapus riwayat yang justru dibaca laporan ═══════════
--
-- 110 menghapus order FINAL (paid/cancelled/void) >6 bulan tiap malam, dengan
-- alasan: "Angka laporan tetap utuh selamanya di sales_daily_summary". Klaim itu
-- TIDAK BENAR dalam praktik:
--
--   • sales_daily_summary (084) adalah tabel WRITE-ONLY. Ia di-refresh tiap
--     malam tapi TAK PERNAH dibaca — nol SELECT/FROM/JOIN di seluruh SQL,
--     owner-panel, maupun mobile.
--   • Laporan yang SEBENARNYA dipakai — FinanceReport, SalesSummary, Dashboard —
--     membaca v_daily_sales / v_profit_loss, dan keduanya `FROM orders` MENTAH.
--
-- Jadi begitu order paid menyeberang usia 6 bulan, ia lenyap dari tabel orders →
-- lenyap dari v_daily_sales/v_profit_loss → lenyap dari SEMUA laporan keuangan.
-- Ringkasan yang seharusnya jadi cadangan permanen tak pernah tersambung.
-- Belum terasa hanya karena belum ada order yang berumur >6 bulan.
--
-- ══ PERBAIKAN (keputusan pemilik: jangan hapus paid) ════════════════════════
--
-- Pangkas HANYA order cancelled/void lama — yang memang TIDAK masuk laporan
-- (v_daily_sales dkk. menyaring status='paid'), jadi membuangnya tak
-- menghilangkan angka apa pun. Order PAID dipertahankan selamanya sehingga
-- laporan lintas-tahun tetap utuh.
--
-- Trade-off yang diterima: tabel orders tumbuh terus untuk order paid. Untuk POS
-- kafe pertumbuhannya lambat & wajar. Bila kelak butuh memangkas paid demi
-- storage, syaratnya adalah MENYAMBUNGKAN dulu v_daily_sales/v_profit_loss agar
-- membaca sales_daily_summary untuk periode lama (union summary + orders baru) —
-- baru setelah itu paid aman dipangkas.
--
-- Sisa fungsi (batch 5000, cutoff WIB, SECURITY DEFINER, jadwal cron) tak
-- berubah. Order aktif tetap tak pernah tersentuh.

CREATE OR REPLACE FUNCTION public.prune_old_orders(p_months INTEGER DEFAULT 12)
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
               - make_interval(months => GREATEST(p_months, 1)))
              AT TIME ZONE 'Asia/Jakarta';

  LOOP
    WITH doomed AS (
      SELECT id FROM orders
      WHERE created_at < v_cutoff
        AND status IN ('cancelled', 'void')   -- ◄ 130: PAID tak lagi dihapus
      LIMIT 5000
    )
    DELETE FROM orders o USING doomed d WHERE o.id = d.id;

    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;

  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_old_orders(INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION public.prune_old_orders(INTEGER) IS
  'Pangkas HANYA order cancelled/void lama (>p_months). Order PAID DIPERTAHANKAN '
  'karena laporan (v_daily_sales/v_profit_loss) membacanya langsung dari tabel '
  'orders; sales_daily_summary tidak pernah dibaca (130). Order aktif tak '
  'pernah dihapus.';

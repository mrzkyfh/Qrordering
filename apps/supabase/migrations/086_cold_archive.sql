-- 086_cold_archive.sql
-- STRATEGI RETENSI #3 — arsip cold data (ubah pertumbuhan raw jadi mendatar).
-- Hapus order final (paid/void/cancelled) yang berumur > ambang bulan.
-- order_items / order_item_options / payments ikut terhapus via ON DELETE CASCADE.
--
-- ⚠️ MANUAL, TIDAK dijadwalkan cron — karena menghapus raw permanen.
-- Fungsi ini SUDAH menjaga LAPORAN tetap utuh: sebelum menghapus, ia memastikan
-- ringkasan harian (sales_daily_summary) sudah terisi untuk semua tanggal yang
-- akan dihapus. Namun DETAIL per-item hilang → bila butuh untuk audit/pajak,
-- EKSPOR dulu (pg_dump / export CSV dari app) SEBELUM memanggil fungsi ini.
--
-- Pemakaian (jalankan manual di SQL Editor, mis. tiap kuartal):
--   SELECT public.archive_cold_orders(18, true);   -- dry-run: lihat jumlah dulu
--   SELECT public.archive_cold_orders(18, false);  -- eksekusi hapus

CREATE OR REPLACE FUNCTION public.archive_cold_orders(
  p_older_than_months INT DEFAULT 18,
  p_dry_run BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_cutoff DATE := (current_date - make_interval(months => p_older_than_months))::date;
  v_target INTEGER;
  v_deleted INTEGER := 0;
  d DATE;
BEGIN
  -- Hitung kandidat.
  SELECT count(*) INTO v_target
  FROM orders
  WHERE created_at < v_cutoff
    AND status IN ('paid', 'void', 'cancelled');

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true, 'cutoff', v_cutoff, 'candidates', v_target,
      'note', 'Jalankan dengan p_dry_run=false untuk menghapus. Pastikan sudah export bila butuh detail.'
    );
  END IF;

  -- SAFETY: pastikan ringkasan harian terisi untuk semua tanggal 'paid'
  -- sebelum cutoff, agar laporan historis tak kehilangan angka.
  FOR d IN
    SELECT DISTINCT (created_at AT TIME ZONE 'Asia/Jakarta')::date
    FROM orders
    WHERE created_at < v_cutoff AND status = 'paid'
  LOOP
    PERFORM public.refresh_sales_daily_summary(d);
  END LOOP;

  -- Hapus (anak-anak ikut via CASCADE).
  DELETE FROM orders
  WHERE created_at < v_cutoff
    AND status IN ('paid', 'void', 'cancelled');
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'dry_run', false, 'cutoff', v_cutoff, 'deleted', v_deleted,
    'note', 'Ringkasan harian sudah di-refresh sebelum hapus — laporan agregat tetap utuh.'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.archive_cold_orders(INT, BOOLEAN) FROM PUBLIC;

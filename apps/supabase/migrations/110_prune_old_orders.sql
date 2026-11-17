-- 110_prune_old_orders.sql
-- Jaga DB "ramping selamanya": hapus order LAMA yang sudah final agar tabel
-- orders/order_items/order_item_options/payments tidak tumbuh tanpa batas.
--
-- Kenapa aman:
--   • Histori LAPORAN sudah diringkas permanen di sales_daily_summary (084),
--     jadi menghapus detail order lama TIDAK menghapus angka laporan harian.
--   • Semua FK ke orders(id) sudah ON DELETE CASCADE (order_items,
--     order_item_options, payments, order_audit_log, partial_refund, audit) atau
--     ON DELETE SET NULL (loyalty_transactions, stock_movements) — hapus order
--     membersihkan anaknya, tak menyisakan baris yatim & tak melanggar FK.
--   • Hanya order FINAL (paid/cancelled/void) yang dihapus. Order aktif TIDAK
--     PERNAH dihapus berapa pun umurnya (jaga-jaga).
--
-- Retensi 6 bulan (dijadwalkan di bawah). Dipilih agar muat paket Supabase free
-- meski dipakai multi-cabang: pada 3 cabang × ~500 order/hari, retensi 12 bulan
-- ~656MB (tembus 500MB free ~bulan ke-9), sedangkan 6 bulan mandek ~328MB (muat).
-- Angka laporan tetap utuh selamanya di sales_daily_summary; yang dipangkas hanya
-- DETAIL order lama. Naikkan argumen (mis. 12) bila sudah pindah ke paket Pro.

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
  -- Ambang umur dihitung dari HARI ini di WIB agar konsisten dgn semantik
  -- tanggal aplikasi (data disimpan UTC, batas usia dihitung waktu lokal).
  v_cutoff := ((now() AT TIME ZONE 'Asia/Jakarta')::date
               - make_interval(months => GREATEST(p_months, 1)))
              AT TIME ZONE 'Asia/Jakarta';

  -- Hapus per-batch (maks 5000/putaran) supaya backlog besar saat pertama
  -- kali jalan tak mengunci tabel lama-lama. CASCADE membereskan anak baris.
  LOOP
    WITH doomed AS (
      SELECT id FROM orders
      WHERE created_at < v_cutoff
        AND status IN ('paid', 'cancelled', 'void')
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

-- Jalan tiap malam 03:20 WIB (= 20:20 UTC), setelah refresh sales_daily_summary
-- (02:30 WIB) & log-db-size — jadi laporan sudah diringkas sebelum detail dihapus.
-- cron.schedule dgn nama sama = upsert; aman dijalankan ulang.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('prune-old-orders', '20 20 * * *',
                     $$SELECT public.prune_old_orders(6);$$);

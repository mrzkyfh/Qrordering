-- 111_security_linter_hardening.sql
-- Tindak lanjut Supabase database linter. HANYA perbaikan yang aman & tak
-- memutus app live. Temuan yang SENGAJA / noise dijelaskan di bawah, tidak diubah.
--
-- ── (1) search_path mutable (WARN 0011) ──────────────────────────────────────
-- 3 fungsi lolos dari hardening massal (061). Pin search_path agar tak bisa
-- dibajak lewat objek bernama sama di schema lain.
ALTER FUNCTION public.apply_stock_transaction()            SET search_path = public;
ALTER FUNCTION public.handle_order_stock_trigger()         SET search_path = public;
ALTER FUNCTION public.validate_order_status_transition()   SET search_path = public;

-- ── (2) security_definer_view (ERROR 0010) — view DIAGNOSTIK admin ────────────
-- v_table_sizes & v_unused_indexes cuma baca pg_catalog (bisa dibaca semua role),
-- jadi aman dijalankan sebagai INVOKER → hilangkan bypass RLS pembuat view.
-- CATATAN: v_outlets_public SENGAJA dibiarkan SECURITY DEFINER — lihat penjelasan
-- di bawah; mengubahnya akan memutus customer-menu.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.views WHERE table_schema='public' AND table_name='v_table_sizes')
    THEN EXECUTE 'ALTER VIEW public.v_table_sizes SET (security_invoker = on)'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.views WHERE table_schema='public' AND table_name='v_unused_indexes')
    THEN EXECUTE 'ALTER VIEW public.v_unused_indexes SET (security_invoker = on)'; END IF;
END $$;

-- ── (3) anon/authenticated bisa panggil fungsi MAINTENANCE (WARN 0028/0029) ───
-- Fungsi ini HANYA dijalankan cron (role postgres, tak terpengaruh grant di
-- bawah). Tak satu pun dipanggil frontend → cabut dari anon & authenticated
-- supaya tak bisa dipicu dari internet (mis. anon memanggil prune → hapus data).
-- (Supabase memberi EXECUTE ke anon/authenticated via DEFAULT PRIVILEGES, jadi
--  REVOKE ... FROM PUBLIC saja tak cukup — harus sebut perannya eksplisit.)
REVOKE EXECUTE ON FUNCTION public.prune_old_orders(integer)            FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.prune_error_logs(integer)           FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.prune_order_audit_log(integer)      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.archive_cold_orders(integer, boolean) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_sales_daily_summary(date)   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.log_db_size()                       FROM anon, authenticated;

-- get_next_order_number hanya dipanggil INTERNAL oleh create_self_order
-- (SECURITY DEFINER → jalan sebagai owner, tak butuh grant pemanggil). Cabut
-- dari anon & authenticated; tak ada jalur frontend langsung.
REVOKE EXECUTE ON FUNCTION public.get_next_order_number(uuid)         FROM anon, authenticated;

-- ── (4) merge_orders: hanya kasir (authenticated), TAK boleh anon ────────────
-- Dipanggil mobile kasir (orders_datasource). anon tak berkepentingan &
-- fungsi ini memutasi data → cabut dari anon saja.
REVOKE EXECUTE ON FUNCTION public.merge_orders(uuid, uuid)            FROM anon;

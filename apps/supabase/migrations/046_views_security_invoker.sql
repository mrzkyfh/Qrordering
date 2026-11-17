-- ============================================================
-- 046_views_security_invoker.sql
-- Fix Supabase Security Advisor: "Security Definer View" (CRITICAL)
--
-- Masalah: view dibuat tanpa opsi security_invoker, sehingga default
-- ke SECURITY DEFINER — query dijalankan dengan hak pembuat view dan
-- MEM-BYPASS RLS. Akibatnya user authenticated berpotensi membaca data
-- outlet lain lewat view laporan.
--
-- Solusi: set security_invoker = on. View dieksekusi dengan hak user
-- yang query, sehingga RLS pada tabel sumber (orders, order_items,
-- menu_items, dll.) ikut ditegakkan. RLS di 005_rls.sql sudah mengizinkan
-- owner/admin membaca data outlet-nya sendiri, jadi laporan tetap jalan.
--
-- CATATAN: v_outlets_public SENGAJA tidak diubah. View itu diakses anon
-- (customer self-order) sebagai proyeksi kolom aman dari tabel outlets.
-- Ia HARUS tetap SECURITY DEFINER agar anon dapat membaca whitelist kolom
-- tanpa akses langsung ke tabel outlets. Warning advisor untuk view itu
-- aman di-acknowledge.
-- ============================================================

ALTER VIEW v_daily_sales        SET (security_invoker = on);
ALTER VIEW v_top_menu_items     SET (security_invoker = on);
ALTER VIEW v_payment_summary    SET (security_invoker = on);
ALTER VIEW v_low_stock          SET (security_invoker = on);
ALTER VIEW v_profit_loss        SET (security_invoker = on);
ALTER VIEW v_kasir_performance  SET (security_invoker = on);
ALTER VIEW v_stock_daily        SET (security_invoker = on);
ALTER VIEW v_loyalty_summary    SET (security_invoker = on);
ALTER VIEW v_category_sales     SET (security_invoker = on);
ALTER VIEW v_peak_hours         SET (security_invoker = on);
ALTER VIEW v_department_sales   SET (security_invoker = on);
ALTER VIEW v_tax_report         SET (security_invoker = on);
ALTER VIEW v_menu_sales         SET (security_invoker = on);
ALTER VIEW v_extra_option_sales SET (security_invoker = on);
ALTER VIEW v_order_hpp          SET (security_invoker = on);
ALTER VIEW v_shift_summary      SET (security_invoker = on);

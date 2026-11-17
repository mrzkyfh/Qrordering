-- ============================================================
-- 063_security_hardening_views_menu_pin.sql
-- Lanjutan hardening linter Supabase.
--
-- (a) Re-assert security_invoker = on untuk semua view laporan (tulis ulang
--     isi migration 046 secara idempoten — jaga-jaga DB live belum/ tak
--     konsisten menerapkannya). v_outlets_public SENGAJA TIDAK diubah
--     (tetap SECURITY DEFINER agar anon/customer baca whitelist kolom outlet).
-- (b) menu_* : baca tetap terbuka, TULIS hanya owner/admin (fix 0024).
-- (c) Cabut anon dari has_my_pin / verify_my_pin (fix 0028); authenticated tetap.
-- ============================================================

-- ── (a) View security_invoker ─────────────────────────────────────────────────
DO $$
DECLARE
  v text;
  views text[] := ARRAY[
    'v_daily_sales','v_top_menu_items','v_payment_summary','v_low_stock',
    'v_profit_loss','v_kasir_performance','v_stock_daily','v_loyalty_summary',
    'v_category_sales','v_peak_hours','v_department_sales','v_tax_report',
    'v_menu_sales','v_extra_option_sales','v_order_hpp','v_shift_summary'
  ];
BEGIN
  FOREACH v IN ARRAY views LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.views
      WHERE table_schema = 'public' AND table_name = v
    ) THEN
      EXECUTE format('ALTER VIEW public.%I SET (security_invoker = on)', v);
    END IF;
  END LOOP;
END $$;

-- ── (b) menu_* : baca terbuka, tulis hanya owner/admin ────────────────────────
-- Helper auth_role() (SECURITY DEFINER) sudah ada sejak RLS awal.
DO $$
DECLARE
  t record;
  tables text[][] := ARRAY[
    ['menu_departments',   'dept_access'],
    ['menu_extras',        'extras_access'],
    ['menu_extra_options', 'extra_options_access'],
    ['menu_item_extras',   'item_extras_access']
  ];
  i int;
  tbl text;
  pol text;
BEGIN
  FOR i IN 1 .. array_length(tables, 1) LOOP
    tbl := tables[i][1];
    pol := tables[i][2];
    -- Lewati jika tabel tak ada (jaga-jaga).
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = tbl
    ) THEN
      CONTINUE;
    END IF;

    -- Hapus policy lama yang selalu-true.
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, tbl);

    -- Baca: terbuka (anon customer-menu + authenticated). SELECT USING(true)
    -- tidak di-flag linter & memang diperlukan untuk menampilkan add-on.
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO public USING (true)',
      pol || '_read', tbl);

    -- Tulis (INSERT/UPDATE/DELETE): hanya owner/admin.
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated '
      'USING (auth_role() IN (''owner'',''admin'')) '
      'WITH CHECK (auth_role() IN (''owner'',''admin''))',
      pol || '_write', tbl);
  END LOOP;
END $$;

-- ── (c) Cabut anon dari has_my_pin / verify_my_pin ────────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('has_my_pin','verify_my_pin')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;
END $$;

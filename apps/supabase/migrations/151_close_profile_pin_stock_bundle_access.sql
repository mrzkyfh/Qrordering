-- 151_close_profile_pin_stock_bundle_access.sql
-- Tutup tiga jalur yang masih terlalu lebar:
-- 1. SELECT tabel profiles membuat hash PIN ikut terbaca lewat select('*').
-- 2. Fungsi mutasi stok internal masih dapat dipanggil langsung authenticated.
-- 3. bundle_items memakai USING (TRUE), sehingga tidak terisolasi per outlet.

-- ── 1. Profiles: ubah SELECT tabel menjadi izin per kolom ────────────────────
-- REVOKE kolom saja tidak cukup bila role masih memiliki SELECT tingkat tabel.
REVOKE SELECT ON TABLE public.profiles FROM authenticated;

GRANT SELECT (
  id,
  outlet_id,
  role,
  full_name,
  login_email,
  phone,
  avatar_url,
  is_active,
  can_refund,
  last_login_at,
  device_last_seen_at,
  device_app_version,
  created_at,
  updated_at
) ON public.profiles TO authenticated;

REVOKE SELECT (
  pin_hash,
  pin_failed_count,
  pin_failed_at
) ON public.profiles FROM authenticated;

-- ── 2. Mutasi stok: hanya jalur server/trigger yang boleh memanggil ──────────
-- Ketiganya dipanggil dari fungsi SECURITY DEFINER:
-- handle_order_stock_trigger, append_order_items, dan RPC void/refund.
REVOKE ALL ON FUNCTION public.deduct_stock_for_order(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.deduct_stock_for_items(UUID, UUID[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.restore_stock_for_order(UUID)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.deduct_stock_for_order(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.deduct_stock_for_items(UUID, UUID[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.restore_stock_for_order(UUID) TO service_role;

-- ── 3. Bundle: baca satu outlet; mutasi hanya pengelola outlet ───────────────
DROP POLICY IF EXISTS "authenticated can manage bundle_items"
  ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_select" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_insert" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_update" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_delete" ON public.bundle_items;

CREATE POLICY "bundle_items_select" ON public.bundle_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND bundle.outlet_id = component.outlet_id
        AND (
          public.is_owner()
          OR bundle.outlet_id = public.auth_outlet_id()
        )
    )
  );

CREATE POLICY "bundle_items_insert" ON public.bundle_items
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND bundle.outlet_id = component.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() IN ('admin', 'manajer')
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

CREATE POLICY "bundle_items_update" ON public.bundle_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND bundle.outlet_id = component.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() IN ('admin', 'manajer')
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND bundle.outlet_id = component.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() IN ('admin', 'manajer')
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

CREATE POLICY "bundle_items_delete" ON public.bundle_items
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND bundle.outlet_id = component.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() IN ('admin', 'manajer')
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

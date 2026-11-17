-- 153_security_advisor_hardening.sql
--
-- Menutup temuan Supabase Security Advisor tanpa memutus POS maupun customer
-- menu:
--   1. v_outlets_public tidak lagi SECURITY DEFINER.
--   2. fungsi trigger/internal tidak lagi dapat dipanggil sebagai RPC.
--   3. bundle_items dibatasi per outlet dan peran.
--   4. bucket publik tetap dapat menyajikan URL objek, tetapi anon tidak dapat
--      membuat daftar seluruh nama berkas.

-- ── 1. Projection publik outlet tanpa SECURITY DEFINER view ─────────────────
-- security_invoker view tidak boleh membaca public.outlets secara langsung:
-- memberikan SELECT kolom settings ke anon juga akan membuka seluruh JSON
-- settings melalui /rest/v1/outlets. Karena itu data yang memang aman untuk
-- pelanggan disalin ke tabel projection khusus.
CREATE TABLE IF NOT EXISTS public.outlets_public_projection (
  id         UUID PRIMARY KEY REFERENCES public.outlets(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  address    TEXT,
  phone      TEXT,
  city       TEXT,
  logo_url   TEXT,
  is_active  BOOLEAN NOT NULL,
  settings   JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
);

ALTER TABLE public.outlets_public_projection ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.outlets_public_projection
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.outlets_public_projection
  TO anon, authenticated;

DROP POLICY IF EXISTS "outlets_public_projection_read"
  ON public.outlets_public_projection;
CREATE POLICY "outlets_public_projection_read"
  ON public.outlets_public_projection
  FOR SELECT TO anon, authenticated
  USING (is_active = TRUE);

CREATE OR REPLACE FUNCTION public.sync_outlet_public_projection()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.outlets_public_projection WHERE id = OLD.id;
    RETURN OLD;
  END IF;

  IF NOT NEW.is_active THEN
    DELETE FROM public.outlets_public_projection WHERE id = NEW.id;
    RETURN NEW;
  END IF;

  v_settings := jsonb_build_object(
    'tax_percent',                 NEW.settings->'tax_percent',
    'tax_active',                  NEW.settings->'tax_active',
    'tax_name',                    NEW.settings->'tax_name',
    'tax_inclusive',               NEW.settings->'tax_inclusive',
    'tax_calculation',             NEW.settings->'tax_calculation',
    'tax_order_types',             NEW.settings->'tax_order_types',
    'taxes',                       NEW.settings->'taxes',
    'service_charge_percent',      NEW.settings->'service_charge_percent',
    'currency',                    NEW.settings->'currency',
    'receipt_footer',              NEW.settings->'receipt_footer',
    'rounding',                    NEW.settings->'rounding',
    'self_order_enabled',          COALESCE(NEW.settings->'self_order_enabled', 'true'::jsonb),
    'self_order_schedule_enabled', COALESCE(NEW.settings->'self_order_schedule_enabled', 'false'::jsonb),
    'self_order_open_time',        COALESCE(NEW.settings->'self_order_open_time', to_jsonb('10:00'::text)),
    'self_order_close_time',       COALESCE(NEW.settings->'self_order_close_time', to_jsonb('22:00'::text)),
    'self_order_closed_message',   COALESCE(
      NEW.settings->'self_order_closed_message',
      to_jsonb('Order online sedang tutup. Silakan datang langsung.'::text)
    ),
    'self_order_require_name',     COALESCE(NEW.settings->'self_order_require_name', 'false'::jsonb),
    'self_order_allow_notes',      COALESCE(NEW.settings->'self_order_allow_notes', 'true'::jsonb),
    'self_order_max_active',       COALESCE(NEW.settings->'self_order_max_active', '15'::jsonb)
  );

  INSERT INTO public.outlets_public_projection (
    id, name, address, phone, city, logo_url, is_active, settings,
    created_at, updated_at
  )
  VALUES (
    NEW.id, NEW.name, NEW.address, NEW.phone, NEW.city, NEW.logo_url,
    NEW.is_active, v_settings, NEW.created_at, NEW.updated_at
  )
  ON CONFLICT (id) DO UPDATE SET
    name       = EXCLUDED.name,
    address    = EXCLUDED.address,
    phone      = EXCLUDED.phone,
    city       = EXCLUDED.city,
    logo_url   = EXCLUDED.logo_url,
    is_active  = EXCLUDED.is_active,
    settings   = EXCLUDED.settings,
    created_at = EXCLUDED.created_at,
    updated_at = EXCLUDED.updated_at;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_outlet_public_projection()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sync_outlet_public_projection ON public.outlets;
CREATE TRIGGER trg_sync_outlet_public_projection
  AFTER INSERT OR UPDATE OR DELETE ON public.outlets
  FOR EACH ROW EXECUTE FUNCTION public.sync_outlet_public_projection();

-- Backfill awal dan buang projection outlet yang sudah nonaktif/terhapus.
DELETE FROM public.outlets_public_projection p
WHERE NOT EXISTS (
  SELECT 1 FROM public.outlets o WHERE o.id = p.id AND o.is_active
);

INSERT INTO public.outlets_public_projection (
  id, name, address, phone, city, logo_url, is_active, settings,
  created_at, updated_at
)
SELECT
  o.id,
  o.name,
  o.address,
  o.phone,
  o.city,
  o.logo_url,
  o.is_active,
  jsonb_build_object(
    'tax_percent',                 o.settings->'tax_percent',
    'tax_active',                  o.settings->'tax_active',
    'tax_name',                    o.settings->'tax_name',
    'tax_inclusive',               o.settings->'tax_inclusive',
    'tax_calculation',             o.settings->'tax_calculation',
    'tax_order_types',             o.settings->'tax_order_types',
    'taxes',                       o.settings->'taxes',
    'service_charge_percent',      o.settings->'service_charge_percent',
    'currency',                    o.settings->'currency',
    'receipt_footer',              o.settings->'receipt_footer',
    'rounding',                    o.settings->'rounding',
    'self_order_enabled',          COALESCE(o.settings->'self_order_enabled', 'true'::jsonb),
    'self_order_schedule_enabled', COALESCE(o.settings->'self_order_schedule_enabled', 'false'::jsonb),
    'self_order_open_time',        COALESCE(o.settings->'self_order_open_time', to_jsonb('10:00'::text)),
    'self_order_close_time',       COALESCE(o.settings->'self_order_close_time', to_jsonb('22:00'::text)),
    'self_order_closed_message',   COALESCE(
      o.settings->'self_order_closed_message',
      to_jsonb('Order online sedang tutup. Silakan datang langsung.'::text)
    ),
    'self_order_require_name',     COALESCE(o.settings->'self_order_require_name', 'false'::jsonb),
    'self_order_allow_notes',      COALESCE(o.settings->'self_order_allow_notes', 'true'::jsonb),
    'self_order_max_active',       COALESCE(o.settings->'self_order_max_active', '15'::jsonb)
  ),
  o.created_at,
  o.updated_at
FROM public.outlets o
WHERE o.is_active
ON CONFLICT (id) DO UPDATE SET
  name       = EXCLUDED.name,
  address    = EXCLUDED.address,
  phone      = EXCLUDED.phone,
  city       = EXCLUDED.city,
  logo_url   = EXCLUDED.logo_url,
  is_active  = EXCLUDED.is_active,
  settings   = EXCLUDED.settings,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at;

CREATE OR REPLACE VIEW public.v_outlets_public AS
SELECT
  id, name, address, phone, city, logo_url, is_active, settings,
  created_at, updated_at
FROM public.outlets_public_projection
WHERE is_active = TRUE;

ALTER VIEW public.v_outlets_public SET (security_invoker = ON);
REVOKE ALL ON public.v_outlets_public FROM PUBLIC;
GRANT SELECT ON public.v_outlets_public TO anon, authenticated;

COMMENT ON VIEW public.v_outlets_public IS
  'Projection outlet yang aman untuk customer menu. security_invoker aktif; '
  'sumbernya hanya berisi kolom dan kunci settings yang memang boleh publik.';

-- ── 2. Fungsi internal bukan endpoint RPC ───────────────────────────────────
-- Semua fungsi di bawah hanya dipanggil trigger, cron, atau fungsi server lain.
-- Trigger dan pemanggilan oleh function owner tetap bekerja tanpa grant API.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND p.proname IN (
        '_self_order_line',
        'apply_stock_transaction',
        'deduct_stock_for_order',
        'enforce_profile_role_rank',
        'enforce_self_order_enabled',
        'enforce_self_order_tax_policy',
        'guard_order_shift_assignment',
        'guard_payment_shift',
        'guard_shift_assignment',
        'protect_profile_self_update',
        'prune_db_size_log',
        'prune_order_daily_counters',
        'refresh_summary_for_refund',
        'restore_stock_for_order',
        'snapshot_order_cogs',
        'sync_outlet_public_projection'
      )
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated',
      r.signature
    );
  END LOOP;
END;
$$;

-- Fungsi baru tidak otomatis menjadi RPC publik. Grant harus selalu eksplisit.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ── 3. bundle_items tenant-scoped ───────────────────────────────────────────
DROP POLICY IF EXISTS "authenticated can manage bundle_items"
  ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_select" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_insert" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_update" ON public.bundle_items;
DROP POLICY IF EXISTS "bundle_items_delete" ON public.bundle_items;

CREATE POLICY "bundle_items_select"
  ON public.bundle_items FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.id = bundle_items.bundle_id
        AND (public.is_owner() OR mi.outlet_id = public.auth_outlet_id())
    )
  );

CREATE POLICY "bundle_items_insert"
  ON public.bundle_items FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.menu_items bundle
      JOIN public.menu_items component
        ON component.id = bundle_items.component_id
      WHERE bundle.id = bundle_items.bundle_id
        AND component.outlet_id = bundle.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() = 'admin'
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

CREATE POLICY "bundle_items_update"
  ON public.bundle_items FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.id = bundle_items.bundle_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() = 'admin'
            AND mi.outlet_id = public.auth_outlet_id()
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
        AND component.outlet_id = bundle.outlet_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() = 'admin'
            AND bundle.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

CREATE POLICY "bundle_items_delete"
  ON public.bundle_items FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.id = bundle_items.bundle_id
        AND (
          public.is_owner()
          OR (
            public.auth_role() = 'admin'
            AND mi.outlet_id = public.auth_outlet_id()
          )
        )
    )
  );

-- ── 4. Bucket publik: URL publik boleh, listing anonim tidak ─────────────────
-- Pada bucket public, getPublicUrl tidak memerlukan SELECT policy. Policy lama
-- justru memungkinkan siapa pun memanen seluruh nama/path berkas.
DROP POLICY IF EXISTS "menu_images_public_read" ON storage.objects;
DROP POLICY IF EXISTS "qr_codes_public_read" ON storage.objects;

-- Owner-panel tetap perlu list menu-images untuk pengelolaan dan pembersihan.
DROP POLICY IF EXISTS "menu_images_auth_read" ON storage.objects;
CREATE POLICY "menu_images_auth_read"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'menu-images'
    AND (
      (SELECT role FROM public.profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::TEXT FROM public.profiles WHERE id = auth.uid()
      )
    )
  );

-- Dua tabel ini sengaja tidak dibaca klien. Tambahkan policy owner agar audit
-- kapasitas dan histori promo tetap dapat diperiksa tanpa membukanya ke staf.
DROP POLICY IF EXISTS "db_size_log_owner_read" ON public.db_size_log;
CREATE POLICY "db_size_log_owner_read"
  ON public.db_size_log FOR SELECT TO authenticated
  USING (public.is_owner());

DROP POLICY IF EXISTS "promo_usages_owner_read" ON public.promo_usages;
CREATE POLICY "promo_usages_owner_read"
  ON public.promo_usages FOR SELECT TO authenticated
  USING (public.is_owner());

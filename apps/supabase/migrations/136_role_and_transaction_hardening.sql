-- 136_role_and_transaction_hardening.sql
-- Audit lanjutan role, absensi, dan transaksi POS.
--
-- Tujuan:
--   1. Perubahan profil staf hanya melalui RPC dengan validasi hierarki.
--   2. Akun nonaktif tidak dapat melakukan absensi; owner dapat memakai outlet
--      aktif yang dipilih di perangkat.
--   3. Direct API tidak dapat mengubah order/item sebagai dapur/pelanggan dan
--      validasi harga item juga berlaku saat UPDATE.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS device_last_seen_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS device_app_version TEXT;

COMMENT ON COLUMN public.profiles.device_last_seen_at IS
  'Heartbeat terakhir akun perangkat cabang, bukan waktu login staf.';
COMMENT ON COLUMN public.profiles.device_app_version IS
  'Versi aplikasi terakhir yang melaporkan heartbeat perangkat.';

-- ── 1. Profile update terkontrol ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_staff_profile(
  p_target UUID,
  p_patch JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   public.user_role;
  v_caller_outlet UUID;
  v_target_role   public.user_role;
  v_target_outlet UUID;
  v_new_role      public.user_role;
  v_new_outlet    UUID;
  v_new_name      TEXT;
  v_new_phone     TEXT;
  v_new_active    BOOLEAN;
  v_new_refund    BOOLEAN;
  v_keys          TEXT[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi' USING ERRCODE = '42501';
  END IF;
  IF p_target IS NULL OR p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'Target dan perubahan profil wajib diisi'
      USING ERRCODE = '22023';
  END IF;

  SELECT role, outlet_id
    INTO v_caller_role, v_caller_outlet
  FROM public.profiles
  WHERE id = auth.uid() AND is_active
    AND role IN ('owner', 'admin');

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Hanya owner/admin aktif yang dapat mengubah profil staf'
      USING ERRCODE = '42501';
  END IF;

  SELECT role, outlet_id, full_name, phone, is_active, can_refund
    INTO v_target_role, v_target_outlet, v_new_name, v_new_phone,
         v_new_active, v_new_refund
  FROM public.profiles
  WHERE id = p_target;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Staff tidak ditemukan' USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(k) INTO v_keys
  FROM jsonb_object_keys(p_patch) AS keys(k);
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(v_keys, ARRAY[]::TEXT[])) AS k
    WHERE k NOT IN ('full_name', 'role', 'outlet_id', 'phone', 'is_active', 'can_refund')
  ) THEN
    RAISE EXCEPTION 'Field profil tidak diizinkan' USING ERRCODE = '42501';
  END IF;

  -- Admin hanya boleh mengelola staf yang lebih rendah di outletnya sendiri.
  IF v_caller_role <> 'owner' THEN
    IF v_target_outlet IS DISTINCT FROM v_caller_outlet
       OR role_rank(v_target_role) >= role_rank(v_caller_role) THEN
      RAISE EXCEPTION 'Tidak berwenang mengubah profil staf ini'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Satu owner tidak dapat mengubah/menghapus hak owner lain lewat panel.
  IF v_target_role = 'owner' AND p_target <> auth.uid() THEN
    RAISE EXCEPTION 'Profil owner lain dilindungi' USING ERRCODE = '42501';
  END IF;
  IF p_target = auth.uid()
     AND (p_patch ? 'role' OR p_patch ? 'outlet_id' OR p_patch ? 'is_active') THEN
    RAISE EXCEPTION 'Role, outlet, dan status akun sendiri tidak dapat diubah'
      USING ERRCODE = '42501';
  END IF;

  v_new_role := v_target_role;
  IF p_patch ? 'role' THEN
    IF jsonb_typeof(p_patch->'role') <> 'string' THEN
      RAISE EXCEPTION 'Role tidak valid' USING ERRCODE = '22023';
    END IF;
    v_new_role := (p_patch->>'role')::public.user_role;
  END IF;

  IF v_new_role = 'owner' AND v_target_role <> 'owner' THEN
    RAISE EXCEPTION 'Promosi menjadi owner harus dilakukan di level sistem'
      USING ERRCODE = '42501';
  END IF;
  IF v_caller_role <> 'owner'
     AND role_rank(v_new_role) >= role_rank(v_caller_role) THEN
    RAISE EXCEPTION 'Tidak boleh mengatur role setara atau lebih tinggi'
      USING ERRCODE = '42501';
  END IF;

  IF p_patch ? 'outlet_id' THEN
    v_new_outlet := CASE
      WHEN p_patch->'outlet_id' = 'null'::jsonb THEN NULL
      ELSE (p_patch->>'outlet_id')::UUID
    END;
  ELSE
    v_new_outlet := v_target_outlet;
  END IF;

  IF v_new_role <> 'owner' AND v_new_outlet IS NULL THEN
    RAISE EXCEPTION 'Staff non-owner wajib memiliki outlet'
      USING ERRCODE = '22023';
  END IF;
  IF v_new_outlet IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.outlets WHERE id = v_new_outlet AND is_active
  ) THEN
    RAISE EXCEPTION 'Outlet tidak aktif atau tidak ditemukan'
      USING ERRCODE = '22023';
  END IF;
  IF v_caller_role <> 'owner' AND v_new_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Admin hanya boleh memindahkan staf di outlet sendiri'
      USING ERRCODE = '42501';
  END IF;

  IF p_patch ? 'full_name' THEN
    v_new_name := NULLIF(btrim(p_patch->>'full_name'), '');
    IF v_new_name IS NULL THEN
      RAISE EXCEPTION 'Nama staf wajib diisi' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_patch ? 'phone' THEN
    v_new_phone := p_patch->>'phone';
  END IF;
  IF p_patch ? 'is_active' THEN
    v_new_active := (p_patch->>'is_active')::BOOLEAN;
    IF p_target = auth.uid() AND NOT v_new_active THEN
      RAISE EXCEPTION 'Akun sendiri tidak dapat dinonaktifkan'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  IF p_patch ? 'can_refund' THEN
    v_new_refund := (p_patch->>'can_refund')::BOOLEAN;
  END IF;

  -- Trigger role-rank lama tetap berlaku untuk jalur internal lain; flag ini
  -- menandai bahwa perubahan sudah melewati pemeriksaan RPC di atas.
  PERFORM set_config('app.staff_profile_update', '1', true);
  UPDATE public.profiles
  SET full_name  = v_new_name,
      role       = v_new_role,
      outlet_id  = v_new_outlet,
      phone      = v_new_phone,
      is_active  = v_new_active,
      can_refund = v_new_refund,
      updated_at = NOW()
  WHERE id = p_target;
END;
$$;

REVOKE ALL ON FUNCTION public.update_staff_profile(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_staff_profile(UUID, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.touch_device_heartbeat(
  p_app_version TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles
  SET device_last_seen_at = NOW(),
      device_app_version = NULLIF(btrim(p_app_version), ''),
      updated_at = NOW()
  WHERE id = auth.uid()
    AND role = 'pelanggan'
    AND is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Akun perangkat tidak aktif atau tidak ditemukan'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.touch_device_heartbeat(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_device_heartbeat(TEXT) TO authenticated;

-- Jalur langsung profiles hanya boleh mengubah profil sendiri. Field privilege
-- tetap dilindungi trigger sehingga API tidak bisa menaikkan hak akses sendiri.
DROP POLICY IF EXISTS "profiles_update" ON public.profiles;
CREATE POLICY "profiles_update" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE OR REPLACE FUNCTION public.protect_profile_self_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL
     OR current_setting('app.staff_profile_update', true) = '1'
     OR NEW.id <> auth.uid() THEN
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role
     OR NEW.outlet_id IS DISTINCT FROM OLD.outlet_id
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.can_refund IS DISTINCT FROM OLD.can_refund
     OR NEW.login_email IS DISTINCT FROM OLD.login_email THEN
    RAISE EXCEPTION 'Field privilege profil hanya dapat diubah melalui jalur resmi'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_profile_self_update ON public.profiles;
CREATE TRIGGER trg_protect_profile_self_update
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_profile_self_update();

-- ── 2. Absensi role-aware dan owner outlet-aware ────────────────────────────
DROP FUNCTION IF EXISTS public.attendance_clock_in(TEXT);
DROP FUNCTION IF EXISTS public.attendance_clock_in(TEXT, UUID);
CREATE FUNCTION public.attendance_clock_in(
  p_note TEXT DEFAULT NULL,
  p_outlet_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_staff       UUID := auth.uid();
  v_role        public.user_role;
  v_profile_outlet UUID;
  v_outlet      UUID;
  v_open        UUID;
BEGIN
  IF v_staff IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT role, outlet_id INTO v_role, v_profile_outlet
  FROM public.profiles
  WHERE id = v_staff AND is_active;
  IF v_role IS NULL OR v_role = 'pelanggan' THEN
    RAISE EXCEPTION 'Akun tidak aktif atau tidak berwenang melakukan absensi'
      USING ERRCODE = '42501';
  END IF;

  v_outlet := COALESCE(p_outlet_id, v_profile_outlet);
  IF v_outlet IS NULL THEN
    RAISE EXCEPTION 'Outlet wajib dipilih';
  END IF;
  IF v_role <> 'owner' AND v_profile_outlet IS DISTINCT FROM v_outlet THEN
    RAISE EXCEPTION 'Absensi hanya dapat dilakukan di outlet akun Anda'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.outlets WHERE id = v_outlet AND is_active) THEN
    RAISE EXCEPTION 'Outlet tidak aktif atau tidak ditemukan';
  END IF;

  SELECT id INTO v_open FROM public.attendances
  WHERE staff_id = v_staff AND outlet_id = v_outlet AND clock_out IS NULL
  ORDER BY clock_in DESC LIMIT 1;
  IF v_open IS NOT NULL THEN RETURN v_open; END IF;

  INSERT INTO public.attendances (outlet_id, staff_id, note)
  VALUES (v_outlet, v_staff, p_note)
  RETURNING id INTO v_open;
  RETURN v_open;
END;
$$;

DROP FUNCTION IF EXISTS public.attendance_clock_out();
DROP FUNCTION IF EXISTS public.attendance_clock_out(UUID);
CREATE FUNCTION public.attendance_clock_out(p_outlet_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_staff UUID := auth.uid();
  v_role public.user_role;
  v_profile_outlet UUID;
  v_outlet UUID;
BEGIN
  IF v_staff IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT role, outlet_id INTO v_role, v_profile_outlet
  FROM public.profiles
  WHERE id = v_staff AND is_active;
  IF v_role IS NULL OR v_role = 'pelanggan' THEN
    RAISE EXCEPTION 'Akun tidak aktif atau tidak berwenang melakukan absensi'
      USING ERRCODE = '42501';
  END IF;

  v_outlet := COALESCE(p_outlet_id, v_profile_outlet);
  IF v_role <> 'owner' AND v_profile_outlet IS DISTINCT FROM v_outlet THEN
    RAISE EXCEPTION 'Absensi hanya dapat dilakukan di outlet akun Anda'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.attendances
  SET clock_out = NOW()
  WHERE id = (
    SELECT id FROM public.attendances
    WHERE staff_id = v_staff
      AND (v_outlet IS NULL OR outlet_id = v_outlet)
      AND clock_out IS NULL
    ORDER BY clock_in DESC LIMIT 1
  );
END;
$$;

REVOKE ALL ON FUNCTION public.attendance_clock_in(TEXT, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.attendance_clock_out(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attendance_clock_in(TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.attendance_clock_out(UUID) TO authenticated;

-- ── 3. Batasi direct transaction write ke role operator ─────────────────────
DROP POLICY IF EXISTS "orders_update" ON public.orders;
CREATE POLICY "orders_update" ON public.orders
  FOR UPDATE TO authenticated
  USING (
    public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
    AND (public.is_owner() OR outlet_id = public.auth_outlet_id())
  )
  WITH CHECK (
    public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
    AND (public.is_owner() OR outlet_id = public.auth_outlet_id())
  );

DROP POLICY IF EXISTS "order_items_update" ON public.order_items;
CREATE POLICY "order_items_update" ON public.order_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

DROP POLICY IF EXISTS "order_items_delete" ON public.order_items;
CREATE POLICY "order_items_delete" ON public.order_items
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.auth_role() IN ('owner', 'admin', 'manajer', 'kasir')
        AND (public.is_owner() OR o.outlet_id = public.auth_outlet_id())
    )
  );

-- Harga katalog juga harus valid ketika item diedit, bukan hanya saat dibuat.
DROP TRIGGER IF EXISTS trg_validate_order_item_price ON public.order_items;
CREATE TRIGGER trg_validate_order_item_price
  BEFORE INSERT OR UPDATE OF menu_item_id, unit_price ON public.order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_order_item_price();

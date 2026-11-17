-- 217_device_auth_boundary_hardening.sql
--
-- Pisahkan akun Perangkat Cabang (`pelanggan`) dari akun operasional. Migration
-- ini hanya mengganti fungsi/trigger/policy: tidak mengubah profil, order,
-- transaksi, token QR, maupun sesi yang sedang tersimpan.

-- Daftar clock-in tetap dapat dibaca oleh akun perangkat dan staf aktif pada
-- outlet yang sama. Staf masih memerlukan fungsi ini saat menyegarkan paket
-- offline setelah clock-in; data yang dikembalikan tetap hanya empat kolom.
CREATE OR REPLACE FUNCTION public.list_clockin_staff(p_outlet UUID)
RETURNS TABLE(
  id UUID,
  full_name TEXT,
  role public.user_role,
  has_pin BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT target.id,
         target.full_name,
         target.role,
         (target.pin_hash IS NOT NULL) AS has_pin
  FROM public.profiles AS target
  JOIN public.profiles AS caller ON caller.id = auth.uid()
  WHERE caller.is_active
    AND caller.role IN ('owner', 'admin', 'manajer', 'kasir', 'pelanggan')
    AND (
      caller.role = 'owner'
      OR (caller.outlet_id = p_outlet AND caller.outlet_id IS NOT NULL)
    )
    AND target.is_active
    AND target.role <> 'pelanggan'
    AND (target.outlet_id = p_outlet OR target.role = 'owner')
  ORDER BY public.role_rank(target.role) DESC, target.full_name
$$;

REVOKE ALL ON FUNCTION public.list_clockin_staff(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_clockin_staff(UUID) TO authenticated;

-- Perubahan akun biasa <-> akun perangkat tidak boleh dilakukan melalui RPC
-- profil umum maupun REST/service-role yang tidak sengaja. Akun perangkat baru
-- tetap dapat dibuat: trigger auth langsung membuat baris dengan role
-- `pelanggan`, sehingga UPDATE pelengkap dari create-staff tidak bertransisi.
CREATE OR REPLACE FUNCTION public.guard_device_role_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (OLD.role = 'pelanggan') IS DISTINCT FROM (NEW.role = 'pelanggan') THEN
    RAISE EXCEPTION
      'Role akun perangkat tidak dapat diubah melalui pengelolaan staf umum'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_device_role_transition ON public.profiles;
CREATE TRIGGER trg_guard_device_role_transition
  BEFORE UPDATE OF role ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_device_role_transition();

REVOKE ALL ON FUNCTION public.guard_device_role_transition()
  FROM PUBLIC, anon, authenticated;

-- Akun perangkat hanya dapat membaca profilnya sendiri melalui REST. Role
-- operasional mempertahankan perilaku lama agar tampilan nama kasir pada APK
-- yang sudah terpasang tidak rusak; daftar picker perangkat memakai RPC minimal
-- list_clockin_staff() di atas.
DROP POLICY IF EXISTS "profiles_select" ON public.profiles;
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT TO authenticated
  USING (
    public.is_owner()
    OR id = auth.uid()
    OR (
      public.auth_role() IN ('admin', 'manajer', 'kasir')
      AND outlet_id = public.auth_outlet_id()
    )
  );

-- Akun perangkat sebelumnya dapat membuat/mengubah shift karena policy hanya
-- memeriksa outlet dan kasir_id. Whitelist role diterapkan pada USING dan WITH
-- CHECK agar perubahan kasir/outlet juga tidak dapat melompati batas.
DROP POLICY IF EXISTS "shifts_insert" ON public.shifts;
CREATE POLICY "shifts_insert" ON public.shifts
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
    OR (
      public.auth_role() = 'kasir'
      AND outlet_id = public.auth_outlet_id()
      AND kasir_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "shifts_update" ON public.shifts;
CREATE POLICY "shifts_update" ON public.shifts
  FOR UPDATE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
    OR (
      public.auth_role() = 'kasir'
      AND outlet_id = public.auth_outlet_id()
      AND kasir_id = auth.uid()
    )
  )
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
    OR (
      public.auth_role() = 'kasir'
      AND outlet_id = public.auth_outlet_id()
      AND kasir_id = auth.uid()
    )
  );

-- Pengeluaran hanya boleh dicatat oleh role pengelola. Kasir menggunakan alur
-- mutasi kas terjaga, bukan INSERT langsung ke tabel expenses.
DROP POLICY IF EXISTS "expenses_insert" ON public.expenses;
CREATE POLICY "expenses_insert" ON public.expenses
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  );

-- INSERT langsung sudah dicabut pada migration 142, tetapi policy lama tetap
-- diperketat sebagai defense-in-depth agar perubahan grant di masa depan tidak
-- otomatis membuka mutasi stok untuk akun perangkat/kasir.
DROP POLICY IF EXISTS "stock_tx_insert" ON public.stock_transactions;
CREATE POLICY "stock_tx_insert" ON public.stock_transactions
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  );

-- PostgreSQL menggabungkan policy permisif dengan OR. Karena itu seluruh nama
-- policy tulis historis dihapus dulu, baru dibuat satu set kanonik role-aware.
DROP POLICY IF EXISTS "extras_access_write" ON public.menu_extras;
DROP POLICY IF EXISTS "extras_insert" ON public.menu_extras;
DROP POLICY IF EXISTS "extras_update" ON public.menu_extras;
DROP POLICY IF EXISTS "extras_delete" ON public.menu_extras;

CREATE POLICY "extras_insert" ON public.menu_extras
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  );
CREATE POLICY "extras_update" ON public.menu_extras
  FOR UPDATE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  )
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  );
CREATE POLICY "extras_delete" ON public.menu_extras
  FOR DELETE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND outlet_id = public.auth_outlet_id()
    )
  );

DROP POLICY IF EXISTS "extra_options_access_write" ON public.menu_extra_options;
DROP POLICY IF EXISTS "meo_insert" ON public.menu_extra_options;
DROP POLICY IF EXISTS "meo_update" ON public.menu_extra_options;
DROP POLICY IF EXISTS "meo_delete" ON public.menu_extra_options;

CREATE POLICY "meo_insert" ON public.menu_extra_options
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_extra_options.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  );
CREATE POLICY "meo_update" ON public.menu_extra_options
  FOR UPDATE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_extra_options.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  )
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_extra_options.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  );
CREATE POLICY "meo_delete" ON public.menu_extra_options
  FOR DELETE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_extra_options.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  );

DROP POLICY IF EXISTS "item_extras_access_write" ON public.menu_item_extras;
DROP POLICY IF EXISTS "mie_insert" ON public.menu_item_extras;
DROP POLICY IF EXISTS "mie_delete" ON public.menu_item_extras;

CREATE POLICY "mie_insert" ON public.menu_item_extras
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_item_extras.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_item_extras.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  );
CREATE POLICY "mie_delete" ON public.menu_item_extras
  FOR DELETE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_item_extras.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
      AND EXISTS (
        SELECT 1 FROM public.menu_extras AS extra
        WHERE extra.id = menu_item_extras.extra_id
          AND extra.outlet_id = public.auth_outlet_id()
      )
    )
  );

DROP POLICY IF EXISTS "recipes_insert" ON public.menu_recipes;
DROP POLICY IF EXISTS "recipes_update" ON public.menu_recipes;
DROP POLICY IF EXISTS "recipes_delete" ON public.menu_recipes;

CREATE POLICY "recipes_insert" ON public.menu_recipes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_recipes.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
    )
  );
CREATE POLICY "recipes_update" ON public.menu_recipes
  FOR UPDATE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_recipes.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
    )
  )
  WITH CHECK (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_recipes.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
    )
  );
CREATE POLICY "recipes_delete" ON public.menu_recipes
  FOR DELETE TO authenticated
  USING (
    public.is_owner()
    OR (
      public.auth_role() IN ('admin', 'manajer')
      AND EXISTS (
        SELECT 1 FROM public.menu_items AS item
        WHERE item.id = menu_recipes.menu_item_id
          AND item.outlet_id = public.auth_outlet_id()
      )
    )
  );

COMMENT ON FUNCTION public.guard_device_role_transition() IS
  'Cegah akun staf umum diubah menjadi akun perangkat atau sebaliknya.';

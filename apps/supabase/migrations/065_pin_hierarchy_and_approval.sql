-- ============================================================
-- 065_pin_hierarchy_and_approval.sql
-- Opsi B: login via PIN (clock-in) + hierarki role + approval void/refund.
--
-- Berisi:
--   1. role_rank()  — peringkat hierarki role
--   2. RLS: tambahkan 'manajer' pada aksi operasional & laporan
--   3. set_staff_pin() — atur PIN tunduk hierarki (web + mobile)
--   4. orders.approved_by + RPC approval void/refund
--   5. enforce trigger void/refund (kasir wajib persetujuan atasan)
--   6. verify_staff_pin() (service_role, utk edge clock-in)
--   7. list_clockin_staff() (anon, daftar staff utk picker clock-in)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── 1. Peringkat hierarki role ───────────────────────────────────────────────
-- owner(4) > admin(3) > manajer(2) > kasir(1) = dapur(1) > pelanggan(0)
CREATE OR REPLACE FUNCTION role_rank(p_role user_role)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_role
    WHEN 'owner'   THEN 4
    WHEN 'admin'   THEN 3
    WHEN 'manajer' THEN 2
    WHEN 'kasir'   THEN 1
    WHEN 'dapur'   THEN 1
    ELSE 0
  END
$$;

-- Helper: peringkat user yang sedang login
CREATE OR REPLACE FUNCTION auth_rank()
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role_rank(role) FROM profiles WHERE id = auth.uid()
$$;

-- ── 2. RLS: manajer = operasional + laporan (bukan kelola produk/staff) ───────
-- Manajer boleh kelola transaksi & melihat data outlet sendiri seperti kasir,
-- tetapi pengelolaan master (produk, staff, dll) tetap milik admin+owner.
-- Tabel operasional sudah mengizinkan siapa pun di outlet (orders/payments/
-- order_items) sehingga manajer otomatis tercakup. Tidak ada policy yang perlu
-- dilonggarkan untuk manajer di luar itu pada tahap ini; biarkan manajer setara
-- kasir untuk akses data, dan kewenangan tambahannya (approve, atur PIN) lewat
-- RPC SECURITY DEFINER di bawah.

-- ── 3. set_staff_pin: atur PIN tunduk hierarki ───────────────────────────────
-- Caller boleh atur PIN target bila role_rank(caller) >= role_rank(target),
-- dan (kecuali owner) berada di outlet yang sama. Dipakai web panel & mobile.
CREATE OR REPLACE FUNCTION set_staff_pin(p_target UUID, p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   user_role;
  v_caller_outlet UUID;
  v_target_role   user_role;
  v_target_outlet UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi';
  END IF;

  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM profiles WHERE id = auth.uid();

  SELECT role, outlet_id INTO v_target_role, v_target_outlet
  FROM profiles WHERE id = p_target;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Staff tidak ditemukan';
  END IF;

  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN harus 4-6 digit angka';
  END IF;

  -- Hierarki: hanya boleh atur PIN untuk level sendiri ke bawah.
  IF role_rank(v_caller_role) < role_rank(v_target_role) THEN
    RAISE EXCEPTION 'Tidak berwenang mengatur PIN role di atas Anda';
  END IF;

  -- Selain owner: target wajib di outlet yang sama.
  IF v_caller_role <> 'owner' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
    RAISE EXCEPTION 'Hanya boleh mengatur PIN staf di outlet yang sama';
  END IF;

  UPDATE profiles
  SET pin_hash = crypt(p_pin, gen_salt('bf')),
      updated_at = NOW()
  WHERE id = p_target;
END;
$$;

GRANT EXECUTE ON FUNCTION set_staff_pin(UUID, TEXT) TO authenticated;

-- admin_set_user_pin (059) tetap ada untuk kompatibilitas; arahkan ke logika baru.
CREATE OR REPLACE FUNCTION admin_set_user_pin(p_user_id UUID, p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  PERFORM set_staff_pin(p_user_id, p_pin);
END;
$$;

-- ── 4. Approval void/refund ───────────────────────────────────────────────────
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS approved_by UUID REFERENCES profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN orders.approved_by IS
  'Staff (Manajer/Admin/Owner) yang menyetujui void/refund via PIN. Pelaku aksi tetap di voided_by/cancelled_by.';

CREATE INDEX IF NOT EXISTS idx_orders_approved_by ON orders(approved_by) WHERE approved_by IS NOT NULL;

-- Cari staff penyetuju (rank >= 2) di outlet order tsb yang PIN-nya cocok.
-- Owner (outlet_id NULL) berlaku lintas-outlet.
CREATE OR REPLACE FUNCTION _find_approver(p_outlet UUID, p_pin TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r RECORD;
BEGIN
  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT id, pin_hash FROM profiles
    WHERE is_active
      AND pin_hash IS NOT NULL
      AND role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet)
  LOOP
    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      RETURN r.id;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

-- Refund (status → cancelled) dengan PIN persetujuan atasan.
CREATE OR REPLACE FUNCTION refund_order_with_approval(
  p_order UUID, p_reason TEXT, p_approver_pin TEXT)
RETURNS TABLE(approver_id UUID, approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_outlet   UUID;
  v_status   order_status;
  v_approver UUID;
BEGIN
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF v_outlet IS NULL THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;
  IF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'Order sudah direfund';
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui refund';
  END IF;

  -- Tandai persetujuan utk transaksi ini agar lolos enforce trigger.
  PERFORM set_config('app.action_approved', '1', true);

  UPDATE orders
  SET status = 'cancelled',
      cancel_reason = p_reason,
      approved_by = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

-- Void (status → void) dengan PIN persetujuan atasan.
CREATE OR REPLACE FUNCTION void_order_with_approval(
  p_order UUID, p_reason TEXT, p_approver_pin TEXT)
RETURNS TABLE(approver_id UUID, approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_outlet   UUID;
  v_status   order_status;
  v_approver UUID;
BEGIN
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF v_outlet IS NULL THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;
  IF v_status = 'void' THEN
    RAISE EXCEPTION 'Order sudah di-void';
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui void';
  END IF;

  PERFORM set_config('app.action_approved', '1', true);

  UPDATE orders
  SET status = 'void',
      void_reason = p_reason,
      approved_by = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

GRANT EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT)   TO authenticated;
-- _find_approver tidak di-grant ke authenticated (helper internal).
REVOKE EXECUTE ON FUNCTION _find_approver(UUID, TEXT) FROM PUBLIC;

-- ── 5. Enforce trigger: kasir wajib persetujuan untuk void & refund ───────────
-- Refund: lolos bila (a) disetujui via RPC (GUC), atau (b) pelaku punya
--         can_refund (owner/admin lewat panel). Selain itu ditolak.
-- Void:   lolos bila (a) disetujui via RPC, atau (b) pelaku rank >= 2
--         (manajer/admin/owner). Kasir tanpa persetujuan ditolak.
-- Konteks service-role (auth.uid() NULL) tidak dibatasi.
CREATE OR REPLACE FUNCTION enforce_refund_permission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approved BOOLEAN := COALESCE(current_setting('app.action_approved', true) = '1', FALSE);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- Refund
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    IF NOT v_approved
       AND NOT COALESCE((SELECT can_refund FROM profiles WHERE id = auth.uid()), FALSE) THEN
      RAISE EXCEPTION 'Refund butuh persetujuan (PIN) Manajer/Owner';
    END IF;
  END IF;

  -- Void
  IF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN
    IF NOT v_approved AND COALESCE(auth_rank(), 0) < 2 THEN
      RAISE EXCEPTION 'Void butuh persetujuan (PIN) Manajer/Owner';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger trg_enforce_refund_permission (058) sudah terpasang; definisi fungsi
-- di atas otomatis menggantikannya.

-- ── 6. verify_staff_pin: utk edge function clock-in (service_role) ────────────
CREATE OR REPLACE FUNCTION verify_staff_pin(p_staff UUID, p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash   TEXT;
  v_active BOOLEAN;
BEGIN
  SELECT pin_hash, is_active INTO v_hash, v_active FROM profiles WHERE id = p_staff;
  IF v_hash IS NULL OR v_active IS NOT TRUE THEN
    RETURN FALSE;
  END IF;
  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RETURN FALSE;
  END IF;
  RETURN v_hash = crypt(p_pin, v_hash);
END;
$$;

REVOKE EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) TO service_role;

-- ── 7. list_clockin_staff: daftar staff utk picker clock-in (anon) ────────────
-- Hanya field aman: id, nama, role, punya PIN?  Tidak membocorkan hash.
CREATE OR REPLACE FUNCTION list_clockin_staff(p_outlet UUID)
RETURNS TABLE(id UUID, full_name TEXT, role user_role, has_pin BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Staff outlet ini + owner (lintas-outlet) agar owner bisa clock-in di mana saja.
  SELECT id, full_name, role, (pin_hash IS NOT NULL)
  FROM profiles
  WHERE is_active
    AND role <> 'pelanggan'
    AND (outlet_id = p_outlet OR role = 'owner')
  ORDER BY role_rank(role) DESC, full_name
$$;

GRANT EXECUTE ON FUNCTION list_clockin_staff(UUID) TO anon, authenticated;

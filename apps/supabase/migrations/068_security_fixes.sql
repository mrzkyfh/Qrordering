-- ============================================================
-- 068_security_fixes.sql
-- Perbaikan keamanan & logika dari audit:
--   K-3  Hapus GUC bypass → gunakan kolom approved_by + column-level security
--   K-4  Sembunyikan pin_hash dari role authenticated
--   T-5  set_staff_pin: rank sama tidak boleh ubah PIN satu sama lain
--   T-2  refund: validasi status order sebelum diproses
--   T-3  void: validasi status order sebelum diproses
--   S-9  Lockout PIN: blokir setelah 5 gagal dalam 5 menit
--   R-3  Seragamkan validasi PIN: tepat 4 digit (bukan 4–6)
-- ============================================================

-- ── K-4: Sembunyikan pin_hash dari authenticated ─────────────────────────────
-- SECURITY DEFINER functions (set_staff_pin, _find_approver, verify_staff_pin)
-- masih bisa akses pin_hash karena berjalan sebagai function owner (postgres).
REVOKE SELECT (pin_hash) ON profiles FROM authenticated;

-- ── K-3 prep: Blokir UPDATE approved_by secara langsung oleh authenticated ───
-- Hanya SECURITY DEFINER RPC yang boleh set kolom ini (berjalan sbg postgres).
REVOKE UPDATE (approved_by) ON TABLE orders FROM authenticated;

-- ── S-9: Kolom lockout PIN ────────────────────────────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS pin_failed_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pin_failed_at    TIMESTAMPTZ;

-- ── K-3 + T-5 + T-2 + T-3 + S-9 + R-3: Ganti semua fungsi PIN & approval ────

-- set_staff_pin: hierarki ketat (rank harus LEBIH TINGGI, kecuali ubah sendiri)
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

  -- R-3: tepat 4 digit
  IF p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'PIN harus tepat 4 digit angka';
  END IF;

  -- Ubah PIN sendiri: selalu boleh
  IF auth.uid() <> p_target THEN
    -- T-5: owner bisa ubah siapa saja; lainnya harus LEBIH TINGGI (strict >)
    IF v_caller_role <> 'owner' AND role_rank(v_caller_role) <= role_rank(v_target_role) THEN
      RAISE EXCEPTION 'Tidak berwenang mengatur PIN role setara atau di atas Anda';
    END IF;

    -- Selain owner: target wajib di outlet yang sama
    IF v_caller_role <> 'owner' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
      RAISE EXCEPTION 'Hanya boleh mengatur PIN staf di outlet yang sama';
    END IF;
  END IF;

  UPDATE profiles
  SET pin_hash        = crypt(p_pin, gen_salt('bf')),
      pin_failed_count = 0,
      pin_failed_at   = NULL,
      updated_at      = NOW()
  WHERE id = p_target;
END;
$$;

-- verify_staff_pin: tambah lockout + reset on success, R-3 tepat 4 digit
CREATE OR REPLACE FUNCTION verify_staff_pin(p_staff UUID, p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash         TEXT;
  v_active       BOOLEAN;
  v_fail_count   INT;
  v_fail_at      TIMESTAMPTZ;
  v_ok           BOOLEAN;
BEGIN
  SELECT pin_hash, is_active, pin_failed_count, pin_failed_at
  INTO v_hash, v_active, v_fail_count, v_fail_at
  FROM profiles WHERE id = p_staff;

  IF v_hash IS NULL OR v_active IS NOT TRUE THEN
    RETURN FALSE;
  END IF;

  -- R-3: tepat 4 digit
  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN FALSE;
  END IF;

  -- S-9: cek lockout (5 gagal dalam 5 menit terakhir)
  IF v_fail_count >= 5 AND v_fail_at IS NOT NULL
     AND v_fail_at > NOW() - INTERVAL '5 minutes' THEN
    RETURN FALSE;  -- masih terkunci
  END IF;

  v_ok := v_hash = crypt(p_pin, v_hash);

  IF v_ok THEN
    UPDATE profiles SET pin_failed_count = 0, pin_failed_at = NULL WHERE id = p_staff;
  ELSE
    UPDATE profiles
    SET pin_failed_count = CASE
          WHEN pin_failed_at IS NULL OR pin_failed_at < NOW() - INTERVAL '5 minutes'
          THEN 1
          ELSE pin_failed_count + 1
        END,
        pin_failed_at = NOW()
    WHERE id = p_staff;
  END IF;

  RETURN v_ok;
END;
$$;

REVOKE EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) TO service_role;

-- _find_approver: R-3 tepat 4 digit + S-9 skip staff terkunci
CREATE OR REPLACE FUNCTION _find_approver(p_outlet UUID, p_pin TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r RECORD;
BEGIN
  -- R-3: tepat 4 digit
  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN NULL;
  END IF;

  FOR r IN
    SELECT id, pin_hash, pin_failed_count, pin_failed_at
    FROM profiles
    WHERE is_active
      AND pin_hash IS NOT NULL
      AND role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet)
      -- S-9: skip staff yang sedang terkunci
      AND NOT (
        pin_failed_count >= 5
        AND pin_failed_at IS NOT NULL
        AND pin_failed_at > NOW() - INTERVAL '5 minutes'
      )
  LOOP
    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      -- Reset lockout on successful approval
      UPDATE profiles SET pin_failed_count = 0, pin_failed_at = NULL WHERE id = r.id;
      RETURN r.id;
    ELSE
      -- Catat percobaan gagal
      UPDATE profiles
      SET pin_failed_count = CASE
            WHEN pin_failed_at IS NULL OR pin_failed_at < NOW() - INTERVAL '5 minutes'
            THEN 1
            ELSE pin_failed_count + 1
          END,
          pin_failed_at = NOW()
      WHERE id = r.id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION _find_approver(UUID, TEXT) FROM PUBLIC;

-- refund_order_with_approval: K-3 hapus GUC, T-2 validasi status
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

  -- T-2: validasi status — hanya order yang sudah terbayar/terlayani yang bisa direfund
  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Order tidak dapat di-refund dari status ini: %', v_status;
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui refund';
  END IF;

  -- K-3: tidak ada lagi GUC — trigger membaca approved_by langsung
  UPDATE orders
  SET status      = 'cancelled',
      cancel_reason = p_reason,
      approved_by = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

-- void_order_with_approval: K-3 hapus GUC, T-3 validasi status
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

  -- T-3: validasi status — tidak bisa void yang sudah cancelled/void
  IF v_status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah di-void atau di-refund';
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui void';
  END IF;

  -- K-3: tidak ada lagi GUC — trigger membaca approved_by langsung
  UPDATE orders
  SET status    = 'void',
      void_reason = p_reason,
      approved_by = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

GRANT EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT)   TO authenticated;

-- ── K-3: Trigger enforce — ganti GUC dengan pengecekan approved_by ────────────
-- Trigger hanya dilewati bila:
--   Refund: approved_by terisi DAN approver rank >= 2, ATAU caller punya can_refund
--   Void:   approved_by terisi DAN approver rank >= 2, ATAU caller rank >= 2
-- approved_by tidak bisa di-set langsung oleh authenticated (REVOKE di atas),
-- sehingga nilai ini HANYA bisa berasal dari SECURITY DEFINER RPC.
CREATE OR REPLACE FUNCTION enforce_refund_permission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approver_rank INT;
BEGIN
  -- Service role (migrasi, backend) melewati semua cek
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;

  -- ── Refund (status → cancelled) ──────────────────────────────────────────
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN

    -- Jalur 1: ada approver sah (set oleh RPC, bukan oleh kasir langsung)
    IF NEW.approved_by IS NOT NULL THEN
      SELECT role_rank(role) INTO v_approver_rank
      FROM profiles WHERE id = NEW.approved_by;
      IF COALESCE(v_approver_rank, 0) >= 2 THEN RETURN NEW; END IF;
    END IF;

    -- Jalur 2: caller sendiri punya flag can_refund (admin/owner via panel)
    IF COALESCE((SELECT can_refund FROM profiles WHERE id = auth.uid()), FALSE) THEN
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Refund butuh persetujuan (PIN) Manajer/Owner';
  END IF;

  -- ── Void (status → void) ─────────────────────────────────────────────────
  IF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN

    -- Jalur 1: ada approver sah
    IF NEW.approved_by IS NOT NULL THEN
      SELECT role_rank(role) INTO v_approver_rank
      FROM profiles WHERE id = NEW.approved_by;
      IF COALESCE(v_approver_rank, 0) >= 2 THEN RETURN NEW; END IF;
    END IF;

    -- Jalur 2: caller sendiri rank >= 2 (manajer/admin/owner aksi langsung)
    IF COALESCE(auth_rank(), 0) >= 2 THEN RETURN NEW; END IF;

    RAISE EXCEPTION 'Void butuh persetujuan (PIN) Manajer/Owner';
  END IF;

  RETURN NEW;
END;
$$;

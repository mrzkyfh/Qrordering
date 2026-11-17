-- ============================================================
-- 070_audit_second_pass.sql
-- Perbaikan dari audit ke-2:
--   B-1  INSERT orders tidak boleh set approved_by atau status non-draft
--   B-2  _find_approver terima p_approver_id opsional → hanya lock 1 staff
--   B-4  verify_staff_pin RAISE EXCEPTION LOCKED ketika terkunci
--        (agar clock-in bisa bedakan pesan "salah" vs "terkunci")
-- ============================================================

-- ── B-1: Cegah INSERT order dengan approved_by atau status selain draft ───────
-- Column-level: authenticated tidak boleh menentukan kolom approved_by di INSERT
REVOKE INSERT (approved_by) ON TABLE orders FROM authenticated;

-- RLS INSERT policy: tambahkan guard status = 'draft' dan approved_by IS NULL
DROP POLICY IF EXISTS "orders_insert" ON orders;
CREATE POLICY "orders_insert" ON orders FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
  AND (status IS NULL OR status = 'draft')
  AND (approved_by IS NULL)
);

-- ── B-2: _find_approver dengan p_approver_id opsional ─────────────────────────
-- Jika p_approver_id diberikan: hanya periksa staff itu (1 fail_count increment).
-- Mencegah DoS lockout semua manajer di outlet dari satu kasir nakal.
CREATE OR REPLACE FUNCTION _find_approver(
  p_outlet      UUID,
  p_pin         TEXT,
  p_approver_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r RECORD;
BEGIN
  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN NULL;
  END IF;

  -- Mode terarah: hanya cek satu approver (mencegah DoS lockout kolateral)
  IF p_approver_id IS NOT NULL THEN
    SELECT id, pin_hash, pin_failed_count, pin_failed_at, role, outlet_id, is_active
    INTO r
    FROM profiles
    WHERE id = p_approver_id
      AND is_active
      AND pin_hash IS NOT NULL
      AND role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet);

    IF r.id IS NULL THEN
      RETURN NULL;  -- staff tidak ditemukan / tidak berwenang
    END IF;

    -- Cek lockout
    IF r.pin_failed_count >= 5
       AND r.pin_failed_at IS NOT NULL
       AND r.pin_failed_at > NOW() - INTERVAL '5 minutes' THEN
      RETURN NULL;
    END IF;

    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      UPDATE profiles SET pin_failed_count = 0, pin_failed_at = NULL WHERE id = r.id;
      RETURN r.id;
    ELSE
      UPDATE profiles
      SET pin_failed_count = CASE
            WHEN pin_failed_at IS NULL OR pin_failed_at < NOW() - INTERVAL '5 minutes'
            THEN 1
            ELSE pin_failed_count + 1
          END,
          pin_failed_at = NOW()
      WHERE id = r.id;
      RETURN NULL;
    END IF;
  END IF;

  -- Mode luas (fallback tanpa approver_id): loop semua, tidak increment fail_count
  -- karena tidak tahu siapa yang sedang dicoba.
  FOR r IN
    SELECT id, pin_hash
    FROM profiles
    WHERE is_active
      AND pin_hash IS NOT NULL
      AND role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet)
      AND NOT (
        pin_failed_count >= 5
        AND pin_failed_at IS NOT NULL
        AND pin_failed_at > NOW() - INTERVAL '5 minutes'
      )
  LOOP
    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      UPDATE profiles SET pin_failed_count = 0, pin_failed_at = NULL WHERE id = r.id;
      RETURN r.id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION _find_approver(UUID, TEXT, UUID) FROM PUBLIC, anon, authenticated;

-- Perbarui RPC approval untuk meneruskan p_approver_id ke _find_approver
CREATE OR REPLACE FUNCTION refund_order_with_approval(
  p_order       UUID,
  p_reason      TEXT,
  p_approver_pin TEXT,
  p_approver_id UUID DEFAULT NULL
)
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
  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Order tidak dapat di-refund dari status ini: %', v_status;
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin, p_approver_id);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui refund';
  END IF;

  UPDATE orders
  SET status        = 'cancelled',
      cancel_reason = p_reason,
      approved_by   = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

CREATE OR REPLACE FUNCTION void_order_with_approval(
  p_order       UUID,
  p_reason      TEXT,
  p_approver_pin TEXT,
  p_approver_id UUID DEFAULT NULL
)
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
  IF v_status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah di-void atau di-refund';
  END IF;

  v_approver := _find_approver(v_outlet, p_approver_pin, p_approver_id);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang menyetujui void';
  END IF;

  UPDATE orders
  SET status      = 'void',
      void_reason = p_reason,
      approved_by = v_approver
  WHERE id = p_order;

  RETURN QUERY
  SELECT v_approver, full_name FROM profiles WHERE id = v_approver;
END;
$$;

GRANT EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT, UUID)   TO authenticated;

-- Cabut grant lama (signature tanpa p_approver_id) jika masih ada
REVOKE EXECUTE ON FUNCTION refund_order_with_approval(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION void_order_with_approval(UUID, TEXT, TEXT)   FROM PUBLIC, anon;

-- ── B-4: verify_staff_pin RAISE EXCEPTION ketika terkunci ─────────────────────
-- RAISE EXCEPTION 'LOCKED:<sisa_detik>' → edge function bisa membedakan
-- "PIN salah" (return FALSE) vs "terkunci" (exception).
CREATE OR REPLACE FUNCTION verify_staff_pin(p_staff UUID, p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash       TEXT;
  v_active     BOOLEAN;
  v_fail_count INT;
  v_fail_at    TIMESTAMPTZ;
  v_ok         BOOLEAN;
  v_remaining  INT;
BEGIN
  SELECT pin_hash, is_active, pin_failed_count, pin_failed_at
  INTO v_hash, v_active, v_fail_count, v_fail_at
  FROM profiles WHERE id = p_staff;

  IF v_hash IS NULL OR v_active IS NOT TRUE THEN
    RETURN FALSE;
  END IF;

  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN FALSE;
  END IF;

  -- Cek lockout — RAISE EXCEPTION agar edge function bisa bedakan dari "PIN salah"
  IF v_fail_count >= 5 AND v_fail_at IS NOT NULL
     AND v_fail_at > NOW() - INTERVAL '5 minutes' THEN
    v_remaining := GREATEST(0,
      EXTRACT(EPOCH FROM (v_fail_at + INTERVAL '5 minutes' - NOW()))::INT);
    RAISE EXCEPTION 'LOCKED:%', v_remaining;
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

REVOKE EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) TO service_role;

-- ============================================================
-- 073_fix_void_refund_and_rank_guards.sql
-- KRITIS : fix syntax _find_approver() di void/refund RPC (072 salah pakai FROM)
-- TINGGI : trigger rank-guard di profiles UPDATE (cegah role escalation)
-- ============================================================

-- ── KRITIS: Perbaiki void & refund RPC ────────────────────────────────────────
-- Migration 072 salah: SELECT id INTO v FROM _find_approver(...)
-- _find_approver mengembalikan UUID scalar, bukan tabel. Harus pakai assignment.

DROP FUNCTION IF EXISTS public.void_order_with_approval(UUID,TEXT,TEXT,UUID);
DROP FUNCTION IF EXISTS public.refund_order_with_approval(UUID,TEXT,TEXT,UUID);

CREATE FUNCTION public.void_order_with_approval(
  p_order        UUID,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approver_id   UUID;
  v_approver_name TEXT;
  v_outlet        UUID;
  v_status        order_status;
BEGIN
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT outlet_id, status INTO v_outlet, v_status
  FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;

  IF v_status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan';
  END IF;

  -- PERBAIKAN: scalar assignment, bukan SELECT ... FROM scalar_function()
  SELECT _find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  SELECT full_name INTO v_approver_name FROM profiles WHERE id = v_approver_id;

  UPDATE orders
  SET status      = 'void',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at  = now()
  WHERE id = p_order;

  RETURN QUERY SELECT v_approver_name;
END;
$$;

CREATE FUNCTION public.refund_order_with_approval(
  p_order        UUID,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approver_id   UUID;
  v_approver_name TEXT;
  v_outlet        UUID;
  v_status        order_status;
BEGIN
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT outlet_id, status INTO v_outlet, v_status
  FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;

  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan refund';
  END IF;

  SELECT _find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  SELECT full_name INTO v_approver_name FROM profiles WHERE id = v_approver_id;

  UPDATE orders
  SET status      = 'refunded',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at  = now()
  WHERE id = p_order;

  PERFORM restore_stock_for_order(p_order);

  RETURN QUERY SELECT v_approver_name;
END;
$$;

REVOKE ALL ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;


-- ── TINGGI: Trigger rank-guard — cegah role escalation via profiles UPDATE ────
-- Tanpa ini, admin bisa update role kasir → admin via Supabase API langsung.

CREATE OR REPLACE FUNCTION public.enforce_profile_role_rank()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Bypass: service role (auth_role() IS NULL = tidak ada JWT)
  IF auth_role() IS NULL THEN RETURN NEW; END IF;
  -- Bypass: owner bebas
  IF auth_role() = 'owner' THEN RETURN NEW; END IF;
  -- Tidak ada perubahan role → lewat
  IF NEW.role = OLD.role THEN RETURN NEW; END IF;

  -- Caller harus punya rank > rank role target saat ini (tidak boleh ubah sesama rank)
  IF role_rank(OLD.role) >= auth_rank() THEN
    RAISE EXCEPTION 'Tidak berwenang mengubah role staff dengan level yang sama atau lebih tinggi';
  END IF;
  -- Role baru yang di-set juga harus di bawah rank caller
  IF role_rank(NEW.role) >= auth_rank() THEN
    RAISE EXCEPTION 'Tidak berwenang mengubah role ke level yang sama atau lebih tinggi';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_profile_role_rank ON profiles;
CREATE TRIGGER trg_enforce_profile_role_rank
  BEFORE UPDATE OF role ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_profile_role_rank();

-- TINGGI-B: Blokir mode luas tanpa approver_id di void/refund RPC.
-- DROP dulu diperlukan karena CREATE OR REPLACE tidak bisa ubah return type.
DROP FUNCTION IF EXISTS public.void_order_with_approval(UUID,TEXT,TEXT,UUID);
DROP FUNCTION IF EXISTS public.refund_order_with_approval(UUID,TEXT,TEXT,UUID);

--
-- _find_approver(UUID, TEXT, UUID DEFAULT NULL) masih menerima NULL sebagai
-- p_approver_id — fallback ke mode luas yang TIDAK mencatat fail_count →
-- attacker bisa bruteforce PIN semua manajer tanpa batas via direct API call.
--
-- Fix: tambahkan guard di level void/refund RPC (bukan di _find_approver agar
-- internal test helper tetap bisa memakai mode luas). Semua client production
-- sudah selalu mengirim p_approver_id (mobile dialog wajib pilih approver).

CREATE OR REPLACE FUNCTION public.void_order_with_approval(
  p_order       UUID,
  p_reason      TEXT,
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
  -- Wajib sertakan approver_id untuk mencegah bruteforce tanpa lockout.
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT outlet_id, status INTO v_outlet, v_status
  FROM orders WHERE id = p_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- Status valid untuk void (T-2): bukan sudah void/cancelled.
  IF v_status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan';
  END IF;

  -- Verifikasi PIN approver (dengan lockout tracking).
  SELECT id INTO v_approver_id
  FROM _find_approver(v_outlet, p_approver_pin, p_approver_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  SELECT full_name INTO v_approver_name
  FROM profiles WHERE id = v_approver_id;

  UPDATE orders
  SET status      = 'void',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at  = now()
  WHERE id = p_order;

  RETURN QUERY SELECT v_approver_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_order_with_approval(
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
  -- Wajib sertakan approver_id untuk mencegah bruteforce tanpa lockout.
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT outlet_id, status INTO v_outlet, v_status
  FROM orders WHERE id = p_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- Status valid untuk refund (T-3): hanya dari paid/served/confirmed/preparing/ready.
  IF v_status NOT IN ('paid', 'served', 'confirmed', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'Status order tidak memungkinkan refund';
  END IF;

  -- Verifikasi PIN approver (dengan lockout tracking).
  SELECT id INTO v_approver_id
  FROM _find_approver(v_outlet, p_approver_pin, p_approver_id);

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  SELECT full_name INTO v_approver_name
  FROM profiles WHERE id = v_approver_id;

  UPDATE orders
  SET status      = 'refunded',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at  = now()
  WHERE id = p_order;

  -- Kembalikan stok bahan baku.
  PERFORM restore_stock_for_order(p_order);

  RETURN QUERY SELECT v_approver_name;
END;
$$;

-- Pastikan privilege tetap benar setelah REPLACE.
REVOKE ALL ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;

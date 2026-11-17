-- ============================================================
-- 047_user_pin_and_refund.sql
-- 1. PIN per user (hak akses aksi sensitif: void / refund)
-- 2. cancel_reason untuk refund (status = 'cancelled')
--
-- PIN disimpan sebagai hash (pgcrypto crypt + bcrypt), bukan plain.
-- Verifikasi via RPC verify_my_pin — hanya untuk user yang login.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── PIN hash di profiles ──────────────────────────────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS pin_hash TEXT;

COMMENT ON COLUMN profiles.pin_hash IS
  'Hash bcrypt PIN user (pgcrypto). NULL = belum set PIN. Jangan pernah di-SELECT ke client.';

-- ── Alasan refund (status cancelled) ──────────────────────────────────────────
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

COMMENT ON COLUMN orders.cancel_reason IS 'Alasan refund/cancel order.';

-- ── RPC: set PIN sendiri ──────────────────────────────────────────────────────
-- Hanya 4–6 digit angka. Hash dengan bcrypt.
CREATE OR REPLACE FUNCTION set_my_pin(p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi';
  END IF;
  IF p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN harus 4–6 digit angka';
  END IF;
  UPDATE profiles
  SET pin_hash = crypt(p_pin, gen_salt('bf')),
      updated_at = NOW()
  WHERE id = auth.uid();
END;
$$;

-- ── RPC: verifikasi PIN sendiri ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verify_my_pin(p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN FALSE;
  END IF;
  SELECT pin_hash INTO v_hash FROM profiles WHERE id = auth.uid();
  IF v_hash IS NULL THEN
    RETURN FALSE;  -- belum set PIN
  END IF;
  RETURN v_hash = crypt(p_pin, v_hash);
END;
$$;

-- ── RPC: cek apakah user sudah punya PIN (tanpa bocorkan hash) ─────────────────
CREATE OR REPLACE FUNCTION has_my_pin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pin_hash IS NOT NULL FROM profiles WHERE id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION set_my_pin(TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION verify_my_pin(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION has_my_pin()        TO authenticated;

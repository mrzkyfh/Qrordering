-- Pastikan percobaan PIN yang datang bersamaan dihitung secara atomik.
-- Tanpa row lock, beberapa request dapat membaca pin_failed_count yang sama
-- lalu saling menimpa sehingga batas percobaan bisa dilewati.

BEGIN;

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
  FROM profiles
  WHERE id = p_staff
  FOR UPDATE;

  IF v_hash IS NULL OR v_active IS NOT TRUE THEN
    RETURN FALSE;
  END IF;

  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN FALSE;
  END IF;

  v_fail_count := COALESCE(v_fail_count, 0);

  IF v_fail_count >= 5 AND v_fail_at IS NOT NULL
     AND v_fail_at > NOW() - INTERVAL '5 minutes' THEN
    v_remaining := GREATEST(
      0,
      EXTRACT(EPOCH FROM (v_fail_at + INTERVAL '5 minutes' - NOW()))::INT
    );
    RAISE EXCEPTION 'LOCKED:%', v_remaining;
  END IF;

  v_ok := v_hash = crypt(p_pin, v_hash);

  IF v_ok THEN
    UPDATE profiles
    SET pin_failed_count = 0,
        pin_failed_at = NULL
    WHERE id = p_staff;
  ELSE
    UPDATE profiles
    SET pin_failed_count = CASE
          WHEN v_fail_at IS NULL OR v_fail_at < NOW() - INTERVAL '5 minutes'
          THEN 1
          ELSE v_fail_count + 1
        END,
        pin_failed_at = NOW()
    WHERE id = p_staff;
  END IF;

  RETURN v_ok;
END;
$$;

REVOKE EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_staff_pin(UUID, TEXT) TO service_role;

COMMIT;

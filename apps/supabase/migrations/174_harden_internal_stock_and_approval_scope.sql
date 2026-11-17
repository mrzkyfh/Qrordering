-- 174_harden_internal_stock_and_approval_scope.sql
-- Tutup dua jalur internal yang masih dapat dipanggil langsung oleh sesi
-- authenticated. Mutasi stok tambahan harus terjadi melalui RPC order yang
-- sudah memvalidasi outlet; approval refund/void harus berasal dari role POS.

REVOKE ALL ON FUNCTION public.deduct_stock_for_items(UUID, UUID[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_stock_for_items(UUID, UUID[])
  TO service_role;

CREATE OR REPLACE FUNCTION public._find_approver(
  p_outlet UUID,
  p_pin TEXT,
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
  -- PIN approval adalah lapisan kedua, bukan pengganti autentikasi pemanggil.
  -- Pelanggan atau JWT yang tidak memiliki profil POS tidak boleh menjalankan
  -- refund/void walaupun mengetahui PIN atasan.
  IF auth.uid() IS NULL
     OR COALESCE(public.auth_role()::TEXT, '') NOT IN
          ('owner', 'admin', 'manajer', 'kasir') THEN
    RETURN NULL;
  END IF;
  IF p_pin !~ '^[0-9]{4}$' THEN
    RETURN NULL;
  END IF;

  -- Mode terarah: hanya cek satu approver (mencegah lockout kolateral).
  IF p_approver_id IS NOT NULL THEN
    SELECT id, pin_hash, pin_failed_count, pin_failed_at, role, outlet_id, is_active
    INTO r
    FROM public.profiles
    WHERE id = p_approver_id
      AND is_active
      AND pin_hash IS NOT NULL
      AND public.role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet);

    IF r.id IS NULL THEN
      RETURN NULL;
    END IF;
    IF r.pin_failed_count >= 5
       AND r.pin_failed_at IS NOT NULL
       AND r.pin_failed_at > NOW() - INTERVAL '5 minutes' THEN
      RETURN NULL;
    END IF;

    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      UPDATE public.profiles
      SET pin_failed_count = 0, pin_failed_at = NULL
      WHERE id = r.id;
      RETURN r.id;
    ELSE
      UPDATE public.profiles
      SET pin_failed_count = CASE
            WHEN pin_failed_at IS NULL OR pin_failed_at < NOW() - INTERVAL '5 minutes'
            THEN 1 ELSE pin_failed_count + 1 END,
          pin_failed_at = NOW()
      WHERE id = r.id;
      RETURN NULL;
    END IF;
  END IF;

  -- Mode fallback tanpa approver_id: loop semua approver pada outlet.
  FOR r IN
    SELECT id, pin_hash
    FROM public.profiles
    WHERE is_active
      AND pin_hash IS NOT NULL
      AND public.role_rank(role) >= 2
      AND (role = 'owner' OR outlet_id = p_outlet)
      AND NOT (
        pin_failed_count >= 5
        AND pin_failed_at IS NOT NULL
        AND pin_failed_at > NOW() - INTERVAL '5 minutes'
      )
  LOOP
    IF r.pin_hash = crypt(p_pin, r.pin_hash) THEN
      UPDATE public.profiles
      SET pin_failed_count = 0, pin_failed_at = NULL
      WHERE id = r.id;
      RETURN r.id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._find_approver(UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.deduct_stock_for_items(UUID, UUID[]) IS
  'Internal-only stock mutation. Must be called by a trusted SECURITY DEFINER RPC.';
COMMENT ON FUNCTION public._find_approver(UUID, TEXT, UUID) IS
  'Internal approval helper; caller must be an authenticated POS role.';

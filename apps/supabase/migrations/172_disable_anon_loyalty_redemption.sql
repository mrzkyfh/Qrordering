-- 172_disable_anon_loyalty_redemption.sql
-- Anonymous self-order dapat memakai QR meja sebagai bukti akses ke menu,
-- tetapi QR meja bukan bukti kepemilikan nomor telepon/member. Karena itu
-- lookup saldo dan penukaran poin tidak boleh tersedia untuk role anon.
-- POS/kasir tetap dapat memakai alur loyalty melalui role authenticated.

REVOKE ALL ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID, TEXT)
  FROM anon;
REVOKE ALL ON FUNCTION public.validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC)
  FROM anon;

GRANT EXECUTE ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_loyalty_redeem(UUID, INTEGER, NUMERIC, NUMERIC)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_anon_self_order_loyalty()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  -- Jangan mengandalkan UI: RPC anonim bisa dipanggil langsung dengan UUID
  -- member dan jumlah poin buatan. Tolak sebelum data order tersimpan.
  IF COALESCE(auth.role(), '') = 'anon'
     AND NEW.order_type = 'self_order'
     AND COALESCE(NEW.redeemed_points, 0) > 0 THEN
    RAISE EXCEPTION 'Penukaran poin harus dilakukan melalui kasir'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_anon_self_order_loyalty() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_anon_self_order_loyalty ON public.orders;
CREATE TRIGGER trg_guard_anon_self_order_loyalty
  BEFORE INSERT OR UPDATE OF redeemed_points ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_anon_self_order_loyalty();

COMMENT ON FUNCTION public.guard_anon_self_order_loyalty() IS
  'Mencegah role anon menukar poin loyalty pada self-order; kasir memakai RPC authenticated.';

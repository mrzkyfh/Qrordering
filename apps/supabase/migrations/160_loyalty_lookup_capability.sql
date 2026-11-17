-- 160_loyalty_lookup_capability.sql
-- Pelanggan anonim wajib membuktikan bahwa ia memegang QR token meja aktif
-- pada outlet yang sama sebelum mencari member berdasarkan nomor telepon.
-- Aplikasi kasir terautentikasi tetap memakai signature dua parameter.

CREATE OR REPLACE FUNCTION public.find_loyalty_member_by_phone(
  p_phone TEXT,
  p_outlet_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member public.loyalty_members%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL
     OR NOT (public.is_owner() OR p_outlet_id = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berizin mencari member pada outlet ini'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_member
  FROM public.loyalty_members
  WHERE outlet_id = p_outlet_id
    AND phone = btrim(p_phone)
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'id', v_member.id,
    'phone', v_member.phone,
    'name', v_member.name,
    'points', v_member.points,
    'tier', v_member.tier
  );
END;
$$;

REVOKE ALL ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.find_loyalty_member_by_phone(
  p_phone TEXT,
  p_outlet_id UUID,
  p_table_token TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member public.loyalty_members%ROWTYPE;
BEGIN
  IF NULLIF(btrim(p_table_token), '') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.restaurant_tables t
       WHERE t.outlet_id = p_outlet_id
         AND t.qr_token = p_table_token
         AND t.is_active = true
     ) THEN
    RAISE EXCEPTION 'QR meja tidak valid atau tidak aktif'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_member
  FROM public.loyalty_members
  WHERE outlet_id = p_outlet_id
    AND phone = btrim(p_phone)
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'id', v_member.id,
    'phone', v_member.phone,
    'name', v_member.name,
    'points', v_member.points,
    'tier', v_member.tier
  );
END;
$$;

REVOKE ALL ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID, TEXT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID, TEXT)
  TO anon, authenticated;

COMMENT ON FUNCTION public.find_loyalty_member_by_phone(TEXT, UUID, TEXT)
IS 'Lookup member pelanggan anonim yang mewajibkan QR token meja aktif pada outlet yang sama.';


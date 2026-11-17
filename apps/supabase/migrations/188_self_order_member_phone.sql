-- Pelanggan QR boleh mengaitkan transaksi ke member untuk MENDAPATKAN poin,
-- tetapi tidak boleh melihat identitas/saldo atau menukar poin hanya dengan
-- mengetahui nomor HP. Nomor dicocokkan sepenuhnya di server dan UUID member
-- tidak pernah dikembalikan ke klien anonim.

CREATE OR REPLACE FUNCTION public._normalize_loyalty_phone(p_phone TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_digits TEXT := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');
BEGIN
  IF v_digits LIKE '62%' THEN
    RETURN '0' || substr(v_digits, 3);
  END IF;
  IF v_digits LIKE '8%' THEN
    RETURN '0' || v_digits;
  END IF;
  RETURN v_digits;
END;
$$;

REVOKE ALL ON FUNCTION public._normalize_loyalty_phone(TEXT)
  FROM PUBLIC, anon, authenticated;

-- Overload publik khusus customer menu. Signature lama dengan p_member_id
-- tetap tersedia selama masa kompatibilitas, tetapi klien baru hanya mengirim
-- nomor HP dan tidak pernah menerima data member.
CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id     UUID,
  p_table_id      UUID,
  p_items         JSONB,
  p_table_token   TEXT,
  p_customer_name TEXT,
  p_notes         TEXT,
  p_promo_code    TEXT,
  p_member_phone  TEXT,
  p_request_id    UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table_id         UUID;
  v_member_id        UUID;
  v_normalized_phone TEXT;
  v_created          JSONB;
  v_order_id         UUID;
BEGIN
  IF length(COALESCE(p_member_phone, '')) > 40 THEN
    RAISE EXCEPTION 'Nomor HP member terlalu panjang'
      USING ERRCODE = '22023';
  END IF;

  -- Validasi capability meja SEBELUM mencocokkan nomor. Pemanggil tanpa QR
  -- aktif tidak boleh memakai RPC ini sebagai oracle data member outlet.
  SELECT t.id
    INTO v_table_id
  FROM public.restaurant_tables t
  JOIN public.outlets o ON o.id = t.outlet_id
  WHERE t.id = p_table_id
    AND t.outlet_id = p_outlet_id
    AND t.qr_token = p_table_token
    AND t.is_active
    AND o.is_active;

  IF v_table_id IS NULL THEN
    RAISE EXCEPTION 'QR meja tidak valid atau sudah tidak aktif'
      USING ERRCODE = '42501';
  END IF;

  v_normalized_phone := public._normalize_loyalty_phone(p_member_phone);
  IF length(v_normalized_phone) BETWEEN 8 AND 16 THEN
    SELECT lm.id
      INTO v_member_id
    FROM public.loyalty_members lm
    WHERE lm.outlet_id = p_outlet_id
      AND lm.is_active
      AND public._normalize_loyalty_phone(lm.phone) = v_normalized_phone
    ORDER BY
      (btrim(lm.phone) = btrim(p_member_phone)) DESC,
      lm.id
    LIMIT 1;
  END IF;

  -- Penukaran poin selalu nol. Trigger keamanan 172 tetap menjadi pertahanan
  -- berlapis bila RPC ini kelak diubah secara tidak sengaja.
  v_created := public.create_self_order(
    p_outlet_id     => p_outlet_id,
    p_table_id      => p_table_id,
    p_items         => p_items,
    p_table_token   => p_table_token,
    p_customer_name => p_customer_name,
    p_notes         => p_notes,
    p_promo_code    => p_promo_code,
    p_member_id     => v_member_id,
    p_redeem_points => 0,
    p_request_id    => p_request_id
  );

  v_order_id := NULLIF(v_created->>'order_id', '')::UUID;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Order tersimpan tanpa ID hasil'
      USING ERRCODE = 'P0001';
  END IF;

  -- Fungsi harga internal hanya menautkan member ketika ada redeem. Untuk
  -- earning-only, tautkan setelah order berhasil dibuat. COALESCE menjaga
  -- replay idempoten agar retry dengan input berbeda tidak mengganti member.
  IF v_member_id IS NOT NULL THEN
    UPDATE public.orders
    SET loyalty_member_id = COALESCE(loyalty_member_id, v_member_id)
    WHERE id = v_order_id
      AND outlet_id = p_outlet_id
      AND table_id = p_table_id;
  END IF;

  RETURN v_created;
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) TO anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) IS
  'Self-order QR dengan nomor HP member earning-only. Server mencocokkan member '
  'tanpa membuka UUID, identitas, saldo, atau penukaran poin kepada pelanggan.';

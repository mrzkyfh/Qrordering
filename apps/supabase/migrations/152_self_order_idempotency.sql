-- 152_self_order_idempotency.sql
-- Cegah pesanan pelanggan ganda ketika order sudah tersimpan tetapi respons
-- jaringan terputus. Klien mengulang request_id yang sama dan server
-- mengembalikan order pertama, bukan membuat order kedua.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS client_request_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_client_request_unique
  ON public.orders(outlet_id, client_request_id)
  WHERE client_request_id IS NOT NULL;

COMMENT ON COLUMN public.orders.client_request_id IS
  'Kunci idempotensi dari klien. Percobaan ulang dengan UUID yang sama '
  'mengembalikan order yang sudah dibuat.';

CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id     UUID,
  p_table_id      UUID,
  p_items         JSONB,
  p_table_token   TEXT,
  p_customer_name TEXT,
  p_notes         TEXT,
  p_promo_code    TEXT,
  p_member_id     UUID,
  p_redeem_points INTEGER,
  p_request_id    UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table_id     UUID;
  v_existing_id UUID;
  v_existing_no TEXT;
  v_created      JSONB;
  v_created_id   UUID;
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'ID permintaan pesanan wajib diisi'
      USING ERRCODE = '22023';
  END IF;

  -- Lock per meja sebelum mengecek order lama. Dua request serentak dengan
  -- request_id sama akan berurutan; request kedua melihat hasil request pertama.
  SELECT t.id
    INTO v_table_id
  FROM public.restaurant_tables t
  JOIN public.outlets o ON o.id = t.outlet_id
  WHERE t.id = p_table_id
    AND t.outlet_id = p_outlet_id
    AND t.qr_token = p_table_token
    AND t.is_active
    AND o.is_active
  FOR UPDATE OF t;

  IF v_table_id IS NULL THEN
    RAISE EXCEPTION 'QR meja tidak valid atau sudah tidak aktif'
      USING ERRCODE = '42501';
  END IF;

  SELECT o.id, o.order_number
    INTO v_existing_id, v_existing_no
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.table_id = p_table_id
    AND o.client_request_id = p_request_id;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'order_id', v_existing_id,
      'order_number', v_existing_no,
      'replayed', true
    );
  END IF;

  -- Gunakan implementasi bertoken dari migration 148. Seluruh validasi harga,
  -- promo, loyalty, pajak, anti-spam, item, dan opsi tetap berada di sana.
  v_created := public.create_self_order(
    p_outlet_id     => p_outlet_id,
    p_table_id      => p_table_id,
    p_items         => p_items,
    p_table_token   => p_table_token,
    p_customer_name => p_customer_name,
    p_notes         => p_notes,
    p_promo_code    => p_promo_code,
    p_member_id     => p_member_id,
    p_redeem_points => p_redeem_points
  );

  v_created_id := NULLIF(v_created->>'order_id', '')::UUID;
  IF v_created_id IS NULL THEN
    RAISE EXCEPTION 'Order tersimpan tanpa ID hasil'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.orders
  SET client_request_id = p_request_id
  WHERE id = v_created_id
    AND outlet_id = p_outlet_id
    AND table_id = p_table_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order hasil tidak ditemukan'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_created || jsonb_build_object('replayed', false);
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER, UUID
) FROM PUBLIC, authenticated;

GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER, UUID
) TO anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER, UUID
) IS
  'Self-order idempoten. request_id sama mengembalikan order pertama agar '
  'percobaan ulang setelah gangguan jaringan tidak membuat pesanan ganda.';

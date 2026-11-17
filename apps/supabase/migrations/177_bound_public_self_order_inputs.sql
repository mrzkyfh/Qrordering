-- 177_bound_public_self_order_inputs.sql
--
-- Batasi input RPC publik agar payload anonim tidak dapat membuat transaksi
-- berukuran tidak wajar atau meminta histori dalam jumlah arbitrer. Batas ini
-- tetap cukup untuk operasional normal: maksimal 50 baris menu, 100 unit/baris,
-- dan 50 order pada satu permintaan histori.

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
  v_existing_id  UUID;
  v_existing_no  TEXT;
  v_created      JSONB;
  v_created_id   UUID;
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'ID permintaan pesanan wajib diisi'
      USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Keranjang kosong' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RAISE EXCEPTION 'Maksimal 50 baris menu per pesanan'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) AS x(value)
    WHERE COALESCE((x.value->>'quantity')::INTEGER, 0) NOT BETWEEN 1 AND 100
  ) THEN
    RAISE EXCEPTION 'Jumlah item harus antara 1 dan 100'
      USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(p_customer_name, '')) > 200
     OR length(COALESCE(p_notes, '')) > 1000
     OR length(COALESCE(p_promo_code, '')) > 100
     OR length(COALESCE(p_table_token, '')) > 256 THEN
    RAISE EXCEPTION 'Data pesanan terlalu panjang'
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

CREATE OR REPLACE FUNCTION public.get_self_orders(p_ids UUID[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(array_length(p_ids, 1), 0) > 50 THEN
    RAISE EXCEPTION 'Maksimal 50 order per permintaan histori'
      USING ERRCODE = '22023';
  END IF;

  RETURN (
    SELECT COALESCE(jsonb_agg(row ORDER BY row->>'created_at' DESC), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
        'id',           o.id,
        'order_number', o.order_number,
        'status',       o.status,
        'total_amount', o.total_amount,
        'created_at',   o.created_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'name', mi.name, 'quantity', oi.quantity))
          FROM public.order_items oi
          JOIN public.menu_items mi ON mi.id = oi.menu_item_id
          WHERE oi.order_id = o.id
        ), '[]'::jsonb)
      ) AS row
      FROM public.orders o
      WHERE o.id = ANY(p_ids)
        AND o.order_type = 'self_order'
    ) t
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_self_orders(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_self_orders(UUID[]) TO anon, authenticated;


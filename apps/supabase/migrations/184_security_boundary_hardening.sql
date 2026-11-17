-- 184_security_boundary_hardening.sql
--
-- Riwayat self-order sebelumnya hanya dilindungi oleh UUID order. Pisahkan
-- kapabilitas baca dari primary key agar mengetahui/menebak ID order saja tidak
-- pernah cukup untuk mengambil rincian pesanan pelanggan.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_access_token UUID;

UPDATE public.orders
SET customer_access_token = gen_random_uuid()
WHERE customer_access_token IS NULL;

ALTER TABLE public.orders
  ALTER COLUMN customer_access_token SET DEFAULT gen_random_uuid(),
  ALTER COLUMN customer_access_token SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS orders_customer_access_token_key
  ON public.orders (customer_access_token);

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
  v_table_id      UUID;
  v_existing_id   UUID;
  v_existing_no   TEXT;
  v_access_token  UUID;
  v_created       JSONB;
  v_created_id    UUID;
  v_item           JSONB;
  v_option         JSONB;
  v_quantity_text  TEXT;
  v_option_count   INTEGER;
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
  IF length(COALESCE(p_customer_name, '')) > 200
     OR length(COALESCE(p_notes, '')) > 1000
     OR length(COALESCE(p_promo_code, '')) > 100
     OR length(COALESCE(p_table_token, '')) > 256 THEN
    RAISE EXCEPTION 'Data pesanan terlalu panjang'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_redeem_points, 0) < 0
     OR COALESCE(p_redeem_points, 0) > 1000000
     OR (COALESCE(p_redeem_points, 0) > 0 AND p_member_id IS NULL) THEN
    RAISE EXCEPTION 'Penukaran poin tidak valid'
      USING ERRCODE = '22023';
  END IF;

  -- Validasi bentuk JSON sebelum fungsi harga otoritatif melakukan cast UUID/
  -- integer. Input rusak harus menghasilkan 22023 yang terkontrol, bukan error
  -- cast internal yang dapat memenuhi log atau mengaburkan penyebab penolakan.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'Format item pesanan tidak valid'
        USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_item->>'menu_item_id', '')
       !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'ID menu tidak valid'
        USING ERRCODE = '22023';
    END IF;

    v_quantity_text := COALESCE(v_item->>'quantity', '');
    IF v_quantity_text !~ '^[0-9]{1,3}$' THEN
      RAISE EXCEPTION 'Jumlah item harus berupa angka antara 1 dan 100'
        USING ERRCODE = '22023';
    END IF;
    IF v_quantity_text::INTEGER NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'Jumlah item harus antara 1 dan 100'
        USING ERRCODE = '22023';
    END IF;
    IF length(COALESCE(v_item->>'notes', '')) > 1000 THEN
      RAISE EXCEPTION 'Catatan item terlalu panjang'
        USING ERRCODE = '22023';
    END IF;

    IF v_item ? 'options' THEN
      IF jsonb_typeof(v_item->'options') <> 'array' THEN
        RAISE EXCEPTION 'Format opsi menu tidak valid'
          USING ERRCODE = '22023';
      END IF;
      v_option_count := jsonb_array_length(v_item->'options');
      IF v_option_count > 30 THEN
        RAISE EXCEPTION 'Maksimal 30 opsi per item'
          USING ERRCODE = '22023';
      END IF;

      FOR v_option IN
        SELECT value FROM jsonb_array_elements(v_item->'options')
      LOOP
        IF jsonb_typeof(v_option) <> 'object'
           OR COALESCE(v_option->>'menu_extra_option_id', '')
              !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
          RAISE EXCEPTION 'ID opsi menu tidak valid'
            USING ERRCODE = '22023';
        END IF;
        IF length(COALESCE(v_option->>'extra_name', '')) > 200
           OR length(COALESCE(v_option->>'option_name', '')) > 200 THEN
          RAISE EXCEPTION 'Nama opsi menu terlalu panjang'
            USING ERRCODE = '22023';
        END IF;
      END LOOP;

      IF (
        SELECT count(DISTINCT (entry.value->>'menu_extra_option_id')::UUID)
        FROM jsonb_array_elements(v_item->'options') AS entry(value)
      ) <> v_option_count THEN
        RAISE EXCEPTION 'Opsi menu tidak boleh duplikat'
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;

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

  SELECT o.id, o.order_number, o.customer_access_token
    INTO v_existing_id, v_existing_no, v_access_token
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.table_id = p_table_id
    AND o.client_request_id = p_request_id;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'order_id', v_existing_id,
      'order_number', v_existing_no,
      'access_token', v_access_token,
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
    AND table_id = p_table_id
  RETURNING customer_access_token INTO v_access_token;

  IF NOT FOUND OR v_access_token IS NULL THEN
    RAISE EXCEPTION 'Order hasil tidak ditemukan'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_created || jsonb_build_object(
    'access_token', v_access_token,
    'replayed', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER, UUID
) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER, UUID
) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_self_orders(p_orders JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_orders IS NULL OR jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'Daftar order tidak valid' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_orders) > 50 THEN
    RAISE EXCEPTION 'Maksimal 50 order per permintaan histori'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_orders) AS entry(value)
    WHERE jsonb_typeof(entry.value) <> 'object'
      OR COALESCE(entry.value->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      OR COALESCE(entry.value->>'access_token', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  ) THEN
    RAISE EXCEPTION 'Identitas order tidak valid' USING ERRCODE = '22023';
  END IF;

  RETURN (
    WITH requested AS (
      SELECT
        (entry.value->>'id')::UUID AS id,
        (entry.value->>'access_token')::UUID AS access_token
      FROM jsonb_array_elements(p_orders) AS entry(value)
    )
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
      FROM requested r
      JOIN public.orders o
        ON o.id = r.id
       AND o.customer_access_token = r.access_token
      WHERE o.order_type = 'self_order'
    ) t
  );
END;
$$;

-- Signature lama menganggap UUID order sebagai rahasia. Cabut akses API;
-- service_role tetap dapat dipakai untuk pemulihan administratif jika perlu.
REVOKE ALL ON FUNCTION public.get_self_orders(UUID[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_self_orders(UUID[]) TO service_role;

REVOKE ALL ON FUNCTION public.get_self_orders(JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_self_orders(JSONB) TO anon, authenticated;

-- View diagnostik ukuran/index adalah data operasional internal, bukan API
-- publik. Owner dashboard tidak menggunakannya.
DO $$
BEGIN
  IF to_regclass('public.v_table_sizes') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON public.v_table_sizes FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.v_table_sizes TO service_role';
  END IF;
  IF to_regclass('public.v_unused_indexes') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON public.v_unused_indexes FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.v_unused_indexes TO service_role';
  END IF;
END;
$$;

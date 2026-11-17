-- 191_qr_menu_visibility.sql
--
-- Owner dapat memilih produk yang diterbitkan ke customer menu QR tanpa
-- memengaruhi produk yang tersedia di POS. Default TRUE menjaga perilaku menu
-- lama. Pembatasan diterapkan pada snapshot publik, jalur fallback anon, dan
-- RPC pembuatan self-order agar produk tersembunyi tidak dapat dipesan dengan
-- memalsukan payload.

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS show_in_qr_menu BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.menu_items.show_in_qr_menu IS
  'Jika true, produk diterbitkan di customer menu QR dan dapat dipesan melalui self-order.';

CREATE INDEX IF NOT EXISTS idx_menu_items_qr_visible
  ON public.menu_items (outlet_id, category_id, sort_order, name)
  WHERE is_active AND is_available AND show_in_qr_menu;

CREATE OR REPLACE FUNCTION public.set_qr_menu_visibility(
  p_outlet_id UUID,
  p_visible_menu_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INTEGER := 0;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin')
     OR NOT (
       COALESCE(public.is_owner(), FALSE)
       OR p_outlet_id = public.auth_outlet_id()
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang mengatur menu QR outlet ini'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(p_visible_menu_ids, ARRAY[]::UUID[])) visible_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.id = visible_id
        AND mi.outlet_id = p_outlet_id
    )
  ) THEN
    RAISE EXCEPTION 'Pilihan menu QR tidak valid untuk outlet ini'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.menu_items mi
  SET show_in_qr_menu = mi.id = ANY(
        COALESCE(p_visible_menu_ids, ARRAY[]::UUID[])
      ),
      updated_at = now()
  WHERE mi.outlet_id = p_outlet_id
    AND mi.is_active
    AND mi.show_in_qr_menu IS DISTINCT FROM (
      mi.id = ANY(COALESCE(p_visible_menu_ids, ARRAY[]::UUID[]))
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.set_qr_menu_visibility(UUID, UUID[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_qr_menu_visibility(UUID, UUID[])
  TO authenticated;

COMMENT ON FUNCTION public.set_qr_menu_visibility(UUID, UUID[]) IS
  'Mengganti daftar produk yang diterbitkan ke menu QR secara atomik per outlet.';

-- Jalur fallback customer menu masih memakai SELECT anon. Produk yang tidak
-- diterbitkan tidak boleh dapat dibaca melalui PostgREST.
DROP POLICY IF EXISTS "menu_items_select_anon" ON public.menu_items;
CREATE POLICY "menu_items_select_anon"
  ON public.menu_items FOR SELECT TO anon
  USING (
    is_available = TRUE
    AND is_active = TRUE
    AND show_in_qr_menu = TRUE
    AND outlet_id IN (
      SELECT id FROM public.outlets WHERE is_active = TRUE
    )
  );

CREATE OR REPLACE FUNCTION public.get_public_menu_snapshot(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table public.restaurant_tables%ROWTYPE;
  v_outlet public.outlets_public_projection%ROWTYPE;
BEGIN
  IF NULLIF(btrim(p_token), '') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT t.*
    INTO v_table
  FROM public.restaurant_tables t
  JOIN public.outlets_public_projection op
    ON op.id = t.outlet_id AND op.is_active
  WHERE t.qr_token = p_token
    AND t.is_active
  LIMIT 1;

  IF v_table.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT op.*
    INTO v_outlet
  FROM public.outlets_public_projection op
  WHERE op.id = v_table.outlet_id
    AND op.is_active;

  IF v_outlet.id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'table', jsonb_build_object(
      'id', v_table.id,
      'table_number', v_table.table_number,
      'area', v_table.area,
      'outlet_id', v_table.outlet_id,
      'is_active', v_table.is_active
    ),
    'outlet', jsonb_build_object(
      'id', v_outlet.id,
      'name', v_outlet.name,
      'address', v_outlet.address,
      'phone', v_outlet.phone,
      'city', v_outlet.city,
      'logo_url', v_outlet.logo_url,
      'is_active', v_outlet.is_active,
      'settings', v_outlet.settings,
      'updated_at', v_outlet.updated_at
    ),
    'categories', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'icon', c.icon,
          'sort_order', c.sort_order
        )
        ORDER BY c.sort_order, c.name
      )
      FROM public.menu_categories c
      WHERE c.outlet_id = v_table.outlet_id
        AND c.is_active
        AND EXISTS (
          SELECT 1
          FROM public.menu_items visible_menu
          WHERE visible_menu.category_id = c.id
            AND visible_menu.outlet_id = v_table.outlet_id
            AND visible_menu.is_active
            AND visible_menu.is_available
            AND visible_menu.show_in_qr_menu
        )
    ), '[]'::JSONB),
    'menu', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', m.id,
          'name', m.name,
          'description', m.description,
          'price', m.price,
          'image_url', m.image_url,
          'category_id', m.category_id,
          'is_featured', m.is_featured,
          'sort_order', m.sort_order
        )
        ORDER BY m.is_featured DESC, m.sort_order, m.name
      )
      FROM public.menu_items m
      WHERE m.outlet_id = v_table.outlet_id
        AND m.is_active
        AND m.is_available
        AND m.show_in_qr_menu
    ), '[]'::JSONB),
    'extras', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'menu_item_id', mie.menu_item_id,
          'menu_extras', jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'type', e.type,
            'selection_type', e.selection_type,
            'sort_order', e.sort_order,
            'menu_extra_options', COALESCE((
              SELECT jsonb_agg(
                jsonb_build_object(
                  'id', opt.id,
                  'name', opt.name,
                  'price', opt.price,
                  'sort_order', opt.sort_order
                )
                ORDER BY opt.sort_order, opt.name
              )
              FROM public.menu_extra_options opt
              WHERE opt.extra_id = e.id
            ), '[]'::JSONB)
          )
        )
        ORDER BY mie.menu_item_id, e.sort_order, e.name
      )
      FROM public.menu_item_extras mie
      JOIN public.menu_items m ON m.id = mie.menu_item_id
      JOIN public.menu_extras e ON e.id = mie.extra_id
      WHERE m.outlet_id = v_table.outlet_id
        AND m.is_active
        AND m.is_available
        AND m.show_in_qr_menu
        AND e.outlet_id = v_table.outlet_id
        AND e.is_active
    ), '[]'::JSONB)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_menu_snapshot(TEXT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_menu_snapshot(TEXT)
  TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_menu_snapshot(TEXT) IS
  'Snapshot customer menu berbasis qr_token yang hanya menerbitkan kategori, menu, dan extra pilihan owner.';

CREATE OR REPLACE FUNCTION public._self_order_line(
  p_outlet_id UUID,
  p_item JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_menu_item_id UUID;
  v_base_price NUMERIC;
  v_options JSONB := '[]'::JSONB;
  v_option_count INTEGER := 0;
  v_matched_option_count INTEGER := 0;
  v_extra_total NUMERIC := 0;
BEGIN
  IF p_item IS NULL OR jsonb_typeof(p_item) <> 'object' THEN
    RAISE EXCEPTION 'Item pesanan tidak valid';
  END IF;

  BEGIN
    v_menu_item_id := NULLIF(BTRIM(p_item->>'menu_item_id'), '')::UUID;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Menu tidak valid';
  END;

  IF v_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'Menu tidak valid';
  END IF;

  SELECT mi.price
    INTO v_base_price
  FROM public.menu_items mi
  WHERE mi.id = v_menu_item_id
    AND mi.outlet_id = p_outlet_id
    AND mi.is_active = TRUE
    AND mi.is_available = TRUE
    AND mi.show_in_qr_menu = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Menu tidak tersedia';
  END IF;

  IF p_item ? 'options' THEN
    IF jsonb_typeof(p_item->'options') <> 'array' THEN
      RAISE EXCEPTION 'Pilihan tambahan tidak valid';
    END IF;
    v_options := p_item->'options';
  END IF;

  v_option_count := jsonb_array_length(v_options);
  IF v_option_count > 30 THEN
    RAISE EXCEPTION 'Pilihan tambahan terlalu banyak';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_options) option_payload
    GROUP BY option_payload->>'menu_extra_option_id'
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan duplikat';
  END IF;

  BEGIN
    SELECT COUNT(*), COALESCE(SUM(meo.price), 0)
      INTO v_matched_option_count, v_extra_total
    FROM jsonb_array_elements(v_options) option_payload
    JOIN public.menu_extra_options meo
      ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
    JOIN public.menu_extras me
      ON me.id = meo.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    JOIN public.menu_item_extras mie
      ON mie.extra_id = me.id
     AND mie.menu_item_id = v_menu_item_id;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak valid';
  END;

  IF v_matched_option_count <> v_option_count THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak tersedia untuk menu ini';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_item_extras mie
    JOIN public.menu_extras me
      ON me.id = mie.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    WHERE mie.menu_item_id = v_menu_item_id
      AND me.type = 'required'
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_options) option_payload
        JOIN public.menu_extra_options meo
          ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
        WHERE meo.extra_id = me.id
      )
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan wajib belum dipilih';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_options) option_payload
    JOIN public.menu_extra_options meo
      ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
    JOIN public.menu_extras me
      ON me.id = meo.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    JOIN public.menu_item_extras mie
      ON mie.extra_id = me.id
     AND mie.menu_item_id = v_menu_item_id
    WHERE me.selection_type = 'single'
    GROUP BY me.id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan tunggal hanya boleh dipilih satu';
  END IF;

  RETURN v_base_price + v_extra_total;
END;
$$;

REVOKE ALL ON FUNCTION public._self_order_line(UUID, JSONB) FROM PUBLIC;

-- 169_server_load_reduction.sql
--
-- Mengurangi round-trip dan jumlah baris yang dibaca aplikasi:
--   1. Penjualan POS memakai pagination + agregat server-side.
--   2. Customer QR mengambil meja, outlet, kategori, menu, dan extra dalam
--      satu snapshot RPC berbasis token.
--   3. Tambah indeks gabungan sesuai pola filter order/shift yang paling sering.

-- ── 1. Halaman Penjualan ringan: daftar ringkas + statistik ─────────────────
CREATE OR REPLACE FUNCTION public.get_pos_sales_page(
  p_outlet_id UUID,
  p_created_by UUID DEFAULT NULL,
  p_kind TEXT DEFAULT 'semua',
  p_date_from TIMESTAMPTZ DEFAULT NULL,
  p_date_to TIMESTAMPTZ DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_offset INTEGER DEFAULT 0,
  p_limit INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH filtered AS MATERIALIZED (
    SELECT
      o.id,
      o.outlet_id,
      o.shift_id,
      o.table_id,
      o.order_number,
      o.order_type,
      o.status,
      o.customer_name,
      o.subtotal,
      o.discount_amount,
      o.tax_amount,
      o.service_charge,
      o.total_amount,
      o.stock_deducted,
      o.kitchen_printed,
      o.created_by,
      o.created_at,
      o.updated_at,
      pr.full_name AS cashier_name,
      t.table_number,
      (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS business_date
    FROM public.orders o
    LEFT JOIN public.profiles pr ON pr.id = o.created_by
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
    WHERE o.outlet_id = p_outlet_id
      AND o.status = 'paid'
      -- Kasir tidak boleh meminta rekap kasir lain dengan memalsukan parameter.
      AND (
        COALESCE(public.auth_role()::TEXT, '') <> 'kasir'
        OR o.created_by = auth.uid()
      )
      AND (p_created_by IS NULL OR o.created_by = p_created_by)
      AND (p_date_from IS NULL OR o.created_at >= p_date_from)
      AND (p_date_to IS NULL OR o.created_at < p_date_to)
      AND (
        COALESCE(NULLIF(btrim(p_kind), ''), 'semua') NOT IN
          ('dinein', 'online', 'kasir')
        OR (p_kind = 'dinein' AND o.order_type = 'dine_in')
        OR (p_kind = 'online' AND o.order_type = 'self_order')
        OR (p_kind = 'kasir' AND o.order_type <> 'self_order')
      )
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
        OR COALESCE(o.customer_name, '') ILIKE '%' || btrim(p_search) || '%'
      )
  ),
  page_rows AS (
    SELECT *
    FROM filtered
    ORDER BY created_at DESC, id DESC
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 100))
  ),
  page_json AS (
    SELECT
      (
        to_jsonb(p)
        - 'cashier_name'
        - 'table_number'
        - 'business_date'
      ) || jsonb_build_object(
        'cashier_name', p.cashier_name,
        'restaurant_tables',
          CASE
            WHEN p.table_number IS NULL THEN NULL
            ELSE jsonb_build_object('table_number', p.table_number)
          END
      ) AS row_data,
      p.created_at,
      p.id
    FROM page_rows p
  ),
  totals AS (
    SELECT
      COUNT(*)::BIGINT AS transaction_count,
      COALESCE(SUM(total_amount), 0)::NUMERIC AS total_sales
    FROM filtered
  ),
  days AS (
    SELECT
      business_date,
      COUNT(*)::BIGINT AS transaction_count,
      COALESCE(SUM(total_amount), 0)::NUMERIC AS total_sales
    FROM filtered
    GROUP BY business_date
  )
  SELECT jsonb_build_object(
    'rows', COALESCE((
      SELECT jsonb_agg(row_data ORDER BY created_at DESC, id DESC)
      FROM page_json
    ), '[]'::JSONB),
    'total_transactions', totals.transaction_count,
    'total_sales', totals.total_sales,
    'average_sales', CASE
      WHEN totals.transaction_count = 0 THEN 0
      ELSE totals.total_sales / totals.transaction_count
    END,
    'has_more',
      totals.transaction_count >
        GREATEST(COALESCE(p_offset, 0), 0)
        + GREATEST(1, LEAST(COALESCE(p_limit, 50), 100)),
    'days', COALESCE((
      SELECT jsonb_object_agg(
        d.business_date::TEXT,
        jsonb_build_object(
          'count', d.transaction_count,
          'total', d.total_sales
        )
      )
      FROM days d
    ), '{}'::JSONB)
  )
  FROM totals;
$$;

REVOKE ALL ON FUNCTION public.get_pos_sales_page(
  UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_sales_page(
  UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER, INTEGER
) TO authenticated;

COMMENT ON FUNCTION public.get_pos_sales_page(
  UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER, INTEGER
) IS
  'Daftar Penjualan POS terpaginasikan. Mengembalikan baris ringkas, statistik '
  'seluruh filter, dan total per hari tanpa memuat order_items/payments.';

-- ── 2. Satu snapshot publik untuk customer menu ─────────────────────────────
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
  'Snapshot customer menu berbasis qr_token: meja, projection outlet publik, '
  'kategori, menu aktif, dan extra dalam satu round-trip.';

-- ── 3. Indeks gabungan untuk query operasional paling sering ────────────────
CREATE INDEX IF NOT EXISTS idx_orders_outlet_status_created_desc
  ON public.orders(outlet_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_outlet_creator_status_created_desc
  ON public.orders(outlet_id, created_by, status, created_at DESC)
  WHERE created_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shifts_outlet_open_start_desc
  ON public.shifts(outlet_id, start_time DESC)
  WHERE end_time IS NULL;

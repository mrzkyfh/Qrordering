-- Satukan void sebagian item dan void seluruh order untuk laporan owner.

CREATE OR REPLACE FUNCTION public.report_void_summary(
  p_outlet_id UUID,
  p_date_from TIMESTAMPTZ,
  p_date_to TIMESTAMPTZ,
  p_order_type public.order_type DEFAULT NULL,
  p_search TEXT DEFAULT NULL
)
RETURNS TABLE (
  total_orders BIGINT,
  total_rows BIGINT,
  total_amount NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH item_voids AS (
    SELECT v.order_id, v.amount
    FROM public.order_item_voids v
    JOIN public.orders o ON o.id = v.order_id
    WHERE v.outlet_id = p_outlet_id
      AND v.voided_at BETWEEN p_date_from AND p_date_to
      AND (p_order_type IS NULL OR o.order_type = p_order_type)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      )
  ),
  whole_void_rows AS (
    SELECT o.id AS order_id, o.total_amount, GREATEST(COUNT(oi.id), 1)::BIGINT AS row_count
    FROM public.orders o
    LEFT JOIN public.order_items oi ON oi.order_id = o.id
    WHERE o.outlet_id = p_outlet_id
      AND o.status = 'void'
      AND o.voided_at BETWEEN p_date_from AND p_date_to
      AND (p_order_type IS NULL OR o.order_type = p_order_type)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      )
      -- Jika semua item dihapus lewat void item, baris item_voids sudah menjadi
      -- detail yang benar; jangan tambahkan baris order kosong bernilai nol.
      AND NOT (
        o.total_amount = 0
        AND NOT EXISTS (SELECT 1 FROM public.order_items x WHERE x.order_id = o.id)
        AND EXISTS (SELECT 1 FROM public.order_item_voids v WHERE v.order_id = o.id)
      )
    GROUP BY o.id, o.total_amount
  ),
  affected_orders AS (
    SELECT order_id FROM item_voids
    UNION
    SELECT order_id FROM whole_void_rows
  )
  SELECT
    (SELECT COUNT(*) FROM affected_orders)::BIGINT,
    (
      (SELECT COUNT(*) FROM item_voids)
      + COALESCE((SELECT SUM(row_count) FROM whole_void_rows), 0)
    )::BIGINT,
    (
      COALESCE((SELECT SUM(amount) FROM item_voids), 0)
      + COALESCE((SELECT SUM(total_amount) FROM whole_void_rows), 0)
    )::NUMERIC;
$$;

CREATE OR REPLACE FUNCTION public.report_void_details(
  p_outlet_id UUID,
  p_date_from TIMESTAMPTZ,
  p_date_to TIMESTAMPTZ,
  p_order_type public.order_type DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  row_id TEXT,
  order_id UUID,
  order_number TEXT,
  status_at TIMESTAMPTZ,
  order_at TIMESTAMPTZ,
  kasir_name TEXT,
  otorisasi_name TEXT,
  product_name TEXT,
  quantity INTEGER,
  subtotal NUMERIC,
  order_type TEXT,
  table_number TEXT,
  order_total NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH rows AS (
    SELECT
      'item:' || v.id::TEXT AS row_id,
      o.id AS order_id,
      o.order_number::TEXT,
      v.voided_at AS status_at,
      o.created_at AS order_at,
      kasir.full_name::TEXT AS kasir_name,
      approver.full_name::TEXT AS otorisasi_name,
      v.menu_name::TEXT AS product_name,
      v.quantity::INTEGER,
      v.amount::NUMERIC AS subtotal,
      o.order_type::TEXT,
      t.table_number::TEXT,
      v.amount::NUMERIC AS order_total
    FROM public.order_item_voids v
    JOIN public.orders o ON o.id = v.order_id
    LEFT JOIN public.profiles kasir ON kasir.id = o.created_by
    LEFT JOIN public.profiles approver ON approver.id = v.approved_by
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
    WHERE v.outlet_id = p_outlet_id
      AND v.voided_at BETWEEN p_date_from AND p_date_to
      AND (p_order_type IS NULL OR o.order_type = p_order_type)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      )

    UNION ALL

    SELECT
      'order:' || o.id::TEXT || ':' || COALESCE(oi.id::TEXT, 'empty') AS row_id,
      o.id AS order_id,
      o.order_number::TEXT,
      o.voided_at AS status_at,
      o.created_at AS order_at,
      kasir.full_name::TEXT AS kasir_name,
      authorizer.full_name::TEXT AS otorisasi_name,
      mi.name::TEXT AS product_name,
      COALESCE(oi.quantity, 0)::INTEGER,
      COALESCE(oi.subtotal, 0)::NUMERIC AS subtotal,
      o.order_type::TEXT,
      t.table_number::TEXT,
      o.total_amount::NUMERIC AS order_total
    FROM public.orders o
    LEFT JOIN public.order_items oi ON oi.order_id = o.id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    LEFT JOIN public.profiles kasir ON kasir.id = o.created_by
    LEFT JOIN public.profiles authorizer ON authorizer.id = o.voided_by
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
    WHERE o.outlet_id = p_outlet_id
      AND o.status = 'void'
      AND o.voided_at BETWEEN p_date_from AND p_date_to
      AND (p_order_type IS NULL OR o.order_type = p_order_type)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      )
      AND NOT (
        o.total_amount = 0
        AND NOT EXISTS (SELECT 1 FROM public.order_items x WHERE x.order_id = o.id)
        AND EXISTS (SELECT 1 FROM public.order_item_voids v WHERE v.order_id = o.id)
      )
  )
  SELECT *
  FROM rows
  ORDER BY status_at DESC, row_id
  LIMIT LEAST(GREATEST(p_limit, 1), 500)
  OFFSET GREATEST(p_offset, 0);
$$;

REVOKE ALL ON FUNCTION public.report_void_summary(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_void_details(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT, INTEGER, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_void_summary(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_void_details(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT, INTEGER, INTEGER
) TO authenticated;

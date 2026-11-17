-- Keep the cashier sales screen consistent with the financial reports:
-- 1. use the latest payment time as the sales time;
-- 2. report net sales after refunds;
-- 3. keep order-type filters mutually exclusive;
-- 4. include archived paid orders for long date ranges.

-- Arsip dapat tumbuh tanpa batas. Simpan fakta penjualan yang sering difilter
-- sebagai kolom agar halaman Penjualan tidak perlu mengurai seluruh JSON arsip
-- pada setiap permintaan.
ALTER TABLE public.transaction_archive_orders
  ADD COLUMN IF NOT EXISTS sales_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS refund_amount NUMERIC(14,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.capture_archive_sales_facts()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_sales_at TIMESTAMPTZ;
  v_refund_amount NUMERIC;
BEGIN
  SELECT MAX(NULLIF(payment.value ->> 'paid_at', '')::TIMESTAMPTZ)
  INTO v_sales_at
  FROM jsonb_array_elements(COALESCE(NEW.payments, '[]'::JSONB)) payment(value);

  SELECT COALESCE(
    SUM(COALESCE(NULLIF(refund.value ->> 'amount', '')::NUMERIC, 0)),
    0
  )
  INTO v_refund_amount
  FROM jsonb_array_elements(COALESCE(NEW.refunds, '[]'::JSONB)) refund(value);

  NEW.sales_at := COALESCE(v_sales_at, NEW.created_at);
  NEW.refund_amount := COALESCE(v_refund_amount, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_capture_archive_sales_facts
  ON public.transaction_archive_orders;
CREATE TRIGGER trg_capture_archive_sales_facts
BEFORE INSERT OR UPDATE OF payments, refunds, created_at
ON public.transaction_archive_orders
FOR EACH ROW
EXECUTE FUNCTION public.capture_archive_sales_facts();

-- Kolom baru bernilai NULL hanya untuk arsip yang sudah ada sebelum migrasi.
-- Menyentuh payments/refunds menjalankan trigger dan mengisi kedua fakta.
UPDATE public.transaction_archive_orders
SET payments = payments,
    refunds = refunds
WHERE sales_at IS NULL;

ALTER TABLE public.transaction_archive_orders
  ALTER COLUMN sales_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_archive_orders_outlet_sales
  ON public.transaction_archive_orders(outlet_id, sales_at DESC);
CREATE INDEX IF NOT EXISTS idx_archive_orders_creator_sales
  ON public.transaction_archive_orders(created_by, sales_at DESC);

REVOKE ALL ON FUNCTION public.capture_archive_sales_facts()
  FROM PUBLIC, anon, authenticated;

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
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH live_source AS (
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
      o.created_by,
      o.created_at,
      o.updated_at,
      o.stock_deducted,
      o.kitchen_printed,
      pr.full_name AS cashier_name,
      t.table_number,
      COALESCE(payment_summary.sales_at, o.created_at) AS sales_at,
      COALESCE(refund_summary.refund_amount, 0)::NUMERIC AS refund_amount,
      FALSE AS archived
    FROM public.orders o
    LEFT JOIN public.profiles pr ON pr.id = o.created_by
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
    LEFT JOIN LATERAL (
      SELECT MAX(p.paid_at) AS sales_at
      FROM public.payments p
      WHERE p.order_id = o.id
    ) payment_summary ON TRUE
    LEFT JOIN LATERAL (
      SELECT SUM(r.amount)::NUMERIC AS refund_amount
      FROM public.refunds r
      WHERE r.order_id = o.id
    ) refund_summary ON TRUE
    WHERE o.outlet_id = p_outlet_id
      AND o.status = 'paid'
      AND (p_created_by IS NULL OR o.created_by = p_created_by)
      AND (
        COALESCE(public.auth_role()::TEXT, '') <> 'kasir'
        OR o.created_by = auth.uid()
      )
  ),
  archive_source AS (
    SELECT
      a.id,
      a.outlet_id,
      a.shift_id,
      a.table_id,
      a.order_number,
      a.order_type,
      a.status,
      a.customer_name,
      a.subtotal,
      a.discount_amount,
      a.tax_amount,
      a.service_charge,
      a.total_amount,
      a.created_by,
      a.created_at,
      a.updated_at,
      TRUE AS stock_deducted,
      TRUE AS kitchen_printed,
      COALESCE(a.cashier_name, pr.full_name) AS cashier_name,
      a.table_number,
      a.sales_at,
      a.refund_amount,
      TRUE AS archived
    FROM public.transaction_archive_orders a
    LEFT JOIN public.profiles pr ON pr.id = a.created_by
    WHERE a.outlet_id = p_outlet_id
      AND a.status = 'paid'
      AND (p_created_by IS NULL OR a.created_by = p_created_by)
      AND (
        COALESCE(public.auth_role()::TEXT, '') <> 'kasir'
        OR a.created_by = auth.uid()
      )
  ),
  source AS (
    SELECT * FROM live_source
    UNION ALL
    SELECT * FROM archive_source
  ),
  filtered AS MATERIALIZED (
    SELECT
      source.*,
      GREATEST(source.total_amount - source.refund_amount, 0)::NUMERIC AS net_total_amount,
      (source.sales_at AT TIME ZONE 'Asia/Jakarta')::DATE AS business_date
    FROM source
    WHERE (p_date_from IS NULL OR source.sales_at >= p_date_from)
      AND (p_date_to IS NULL OR source.sales_at < p_date_to)
      AND (
        COALESCE(NULLIF(LOWER(BTRIM(p_kind)), ''), 'semua') NOT IN ('dinein', 'takeaway', 'online', 'kasir')
        OR (LOWER(BTRIM(p_kind)) = 'dinein' AND source.order_type = 'dine_in')
        OR (LOWER(BTRIM(p_kind)) = 'takeaway' AND source.order_type = 'takeaway')
        OR (LOWER(BTRIM(p_kind)) = 'online' AND source.order_type = 'self_order')
        -- Backward compatibility for older app builds.
        OR (LOWER(BTRIM(p_kind)) = 'kasir' AND source.order_type <> 'self_order')
      )
      AND (
        NULLIF(BTRIM(p_search), '') IS NULL
        OR COALESCE(source.customer_name, '') ILIKE '%' || BTRIM(p_search) || '%'
        OR COALESCE(source.order_number, '') ILIKE '%' || BTRIM(p_search) || '%'
      )
  ),
  page_rows AS MATERIALIZED (
    SELECT *
    FROM filtered
    ORDER BY sales_at DESC, id DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 100))
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ),
  page_json AS (
    SELECT COALESCE(
      JSONB_AGG(
        (
          TO_JSONB(page_rows)
          - 'table_number'
          - 'business_date'
          - 'refund_amount'
        )
        || JSONB_BUILD_OBJECT(
          'restaurant_tables', CASE
            WHEN page_rows.table_number IS NULL THEN NULL
            ELSE JSONB_BUILD_OBJECT('table_number', page_rows.table_number)
          END
        )
        ORDER BY page_rows.sales_at DESC, page_rows.id DESC
      ),
      '[]'::JSONB
    ) AS rows
    FROM page_rows
  ),
  total_summary AS (
    SELECT
      COUNT(*)::BIGINT AS transaction_count,
      COALESCE(SUM(net_total_amount), 0)::NUMERIC AS total_sales
    FROM filtered
  ),
  day_summary AS (
    SELECT
      business_date,
      COUNT(*)::BIGINT AS transaction_count,
      COALESCE(SUM(net_total_amount), 0)::NUMERIC AS total_amount
    FROM filtered
    GROUP BY business_date
    ORDER BY business_date DESC
  ),
  day_json AS (
    SELECT COALESCE(
      JSONB_OBJECT_AGG(
        day_summary.business_date::TEXT,
        JSONB_BUILD_OBJECT(
          'count', day_summary.transaction_count,
          'total', day_summary.total_amount
        )
      ),
      '{}'::JSONB
    ) AS days
    FROM day_summary
  )
  SELECT JSONB_BUILD_OBJECT(
    'rows', page_json.rows,
    'total_transactions', total_summary.transaction_count,
    'total_sales', total_summary.total_sales,
    'average_sales', CASE
      WHEN total_summary.transaction_count = 0 THEN 0
      ELSE total_summary.total_sales / total_summary.transaction_count
    END,
    'has_more',
      total_summary.transaction_count
        > GREATEST(COALESCE(p_offset, 0), 0)
          + GREATEST(1, LEAST(COALESCE(p_limit, 50), 100)),
    'days', day_json.days
  )
  INTO v_result
  FROM page_json
  CROSS JOIN total_summary
  CROSS JOIN day_json;

  RETURN COALESCE(
    v_result,
    JSONB_BUILD_OBJECT(
      'rows', '[]'::JSONB,
      'total_transactions', 0,
      'total_sales', 0,
      'average_sales', 0,
      'has_more', FALSE,
      'days', '{}'::JSONB
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_sales_page(
  UUID,
  UUID,
  TEXT,
  TIMESTAMPTZ,
  TIMESTAMPTZ,
  TEXT,
  INTEGER,
  INTEGER
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_pos_sales_page(
  UUID,
  UUID,
  TEXT,
  TIMESTAMPTZ,
  TIMESTAMPTZ,
  TEXT,
  INTEGER,
  INTEGER
) TO authenticated;

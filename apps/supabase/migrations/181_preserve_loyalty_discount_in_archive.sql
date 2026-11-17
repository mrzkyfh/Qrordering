-- 181_preserve_loyalty_discount_in_archive.sql
-- Pastikan penukaran poin loyalty tetap dapat diaudit setelah order aktif
-- dipindahkan ke arsip 90 hari dan tetap tersedia melalui RPC laporan.

ALTER TABLE public.transaction_archive_orders
  ADD COLUMN IF NOT EXISTS loyalty_discount NUMERIC(14,2) NOT NULL DEFAULT 0;

-- finalize_transaction_archive versi lama tidak menyebut kolom baru dalam
-- INSERT. Trigger ini mengambil snapshot dari order aktif sebelum header order
-- dihapus pada akhir finalisasi, tanpa harus menggandakan fungsi finalisasi yang
-- panjang dan berisiko tertinggal dari perubahan berikutnya.
CREATE OR REPLACE FUNCTION public.capture_archive_loyalty_discount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_loyalty_discount NUMERIC(14,2);
BEGIN
  SELECT COALESCE(o.loyalty_discount, 0)
  INTO v_loyalty_discount
  FROM public.orders o
  WHERE o.id = NEW.id;

  -- Pertahankan nilai eksplisit saat baris dimasukkan oleh proses pemulihan
  -- dan header order aktif memang sudah tidak ada.
  IF FOUND THEN
    NEW.loyalty_discount := v_loyalty_discount;
  ELSE
    NEW.loyalty_discount := COALESCE(NEW.loyalty_discount, 0);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_capture_archive_loyalty_discount
  ON public.transaction_archive_orders;
CREATE TRIGGER trg_capture_archive_loyalty_discount
BEFORE INSERT ON public.transaction_archive_orders
FOR EACH ROW
EXECUTE FUNCTION public.capture_archive_loyalty_discount();

REVOKE ALL ON FUNCTION public.capture_archive_loyalty_discount()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.list_orders_unified(
  p_outlet_id UUID,
  p_date_from TIMESTAMPTZ DEFAULT NULL,
  p_date_to TIMESTAMPTZ DEFAULT NULL,
  p_status public.order_status DEFAULT NULL,
  p_order_type public.order_type DEFAULT NULL,
  p_created_by UUID DEFAULT NULL,
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
  WITH base AS (
    SELECT
      o.id, o.outlet_id, o.shift_id, o.table_id, o.order_number, o.order_type,
      o.status, o.customer_name, o.subtotal, o.discount_amount,
      COALESCE(o.loyalty_discount, 0)::NUMERIC(14,2) AS loyalty_discount,
      o.tax_amount, o.service_charge, o.total_amount, o.stock_deducted,
      o.created_by, o.created_at, o.updated_at,
      CASE WHEN t.id IS NULL THEN NULL ELSE
        jsonb_build_object(
          'id', t.id, 'outlet_id', t.outlet_id, 'table_number', t.table_number,
          'area', t.area, 'capacity', t.capacity, 'status', t.status,
          'qr_token', t.qr_token, 'qr_code_url', t.qr_code_url,
          'qr_generated_at', t.qr_generated_at, 'is_active', t.is_active
        )
      END AS restaurant_tables,
      false AS archived,
      NULL::TEXT AS archive_path,
      NULL::TEXT AS archived_cashier_name,
      NULL::JSONB AS archived_payments
    FROM public.orders o
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id

    UNION ALL

    SELECT
      a.id, a.outlet_id, a.shift_id, a.table_id, a.order_number, a.order_type,
      a.status, a.customer_name, a.subtotal, a.discount_amount,
      COALESCE(a.loyalty_discount, 0)::NUMERIC(14,2),
      a.tax_amount, a.service_charge, a.total_amount, true, a.created_by,
      a.created_at, a.updated_at,
      CASE WHEN a.table_number IS NULL THEN NULL ELSE
        jsonb_build_object(
          'id', a.table_id, 'outlet_id', a.outlet_id,
          'table_number', a.table_number, 'area', a.table_area,
          'capacity', 0, 'status', 'available', 'qr_token', NULL,
          'qr_code_url', NULL, 'qr_generated_at', NULL, 'is_active', false
        )
      END,
      true, a.storage_path, a.cashier_name, a.payments
    FROM public.transaction_archive_orders a
  ), filtered AS (
    SELECT *
    FROM base b
    WHERE b.outlet_id = p_outlet_id
      AND (p_date_from IS NULL OR b.created_at >= p_date_from)
      AND (p_date_to IS NULL OR b.created_at <= p_date_to)
      AND (p_status IS NULL OR b.status = p_status)
      AND (p_order_type IS NULL OR b.order_type = p_order_type)
      AND (p_created_by IS NULL OR b.created_by = p_created_by)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR b.order_number ILIKE '%' || btrim(p_search) || '%'
        OR COALESCE(b.customer_name, '') ILIKE '%' || btrim(p_search) || '%'
      )
  ), page AS (
    SELECT *
    FROM filtered
    ORDER BY created_at DESC, id DESC
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 1000))
  ), enriched AS (
    SELECT
      to_jsonb(p) - 'archived_payments'
      || jsonb_build_object(
        'order_items',
        CASE WHEN p.archived THEN '[]'::JSONB ELSE COALESCE((
          SELECT jsonb_agg(
            to_jsonb(oi) || jsonb_build_object(
              'menu_items', jsonb_build_object(
                'id', mi.id,
                'name', COALESCE(mi.name, 'Menu dihapus')
              )
            )
            ORDER BY oi.id
          )
          FROM public.order_items oi
          LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
          WHERE oi.order_id = p.id
        ), '[]'::JSONB) END,
        'payments',
        CASE WHEN p.archived THEN COALESCE(p.archived_payments, '[]'::JSONB)
        ELSE COALESCE((
          SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
          FROM public.payments pay
          WHERE pay.order_id = p.id
        ), '[]'::JSONB) END
      ) AS row_data,
      p.created_at,
      p.id
    FROM page p
  )
  SELECT jsonb_build_object(
    'total_count', (SELECT COUNT(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(e.row_data ORDER BY e.created_at DESC, e.id DESC)
      FROM enriched e
    ), '[]'::JSONB)
  );
$$;

REVOKE ALL ON FUNCTION public.list_orders_unified(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type,
  UUID, TEXT, INTEGER, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_orders_unified(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type,
  UUID, TEXT, INTEGER, INTEGER
) TO authenticated;

COMMENT ON COLUMN public.transaction_archive_orders.loyalty_discount IS
  'Snapshot potongan rupiah dari penukaran poin loyalty saat order diarsipkan.';

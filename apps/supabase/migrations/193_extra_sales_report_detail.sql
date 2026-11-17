-- Laporan Extra: sediakan jumlah bruto, refund, dan penjualan bersih per opsi.
-- Fungsi v1 tetap dipertahankan agar klien lama tidak terganggu.

CREATE OR REPLACE FUNCTION public.report_extra_option_sales_v2(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  option_id UUID,
  qty_selected BIGINT,
  qty_refunded BIGINT,
  gross_revenue NUMERIC,
  refund_amount NUMERIC,
  total_revenue NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    meo.id AS option_id,
    COALESCE(SUM(oi.quantity) FILTER (WHERE o.id IS NOT NULL), 0)::BIGINT AS qty_selected,
    COALESCE(SUM(COALESCE(oi.refunded_qty, 0)) FILTER (WHERE o.id IS NOT NULL), 0)::BIGINT AS qty_refunded,
    COALESCE(SUM(oio.price * oi.quantity) FILTER (WHERE o.id IS NOT NULL), 0)::NUMERIC AS gross_revenue,
    COALESCE(SUM(oio.price * COALESCE(oi.refunded_qty, 0)) FILTER (WHERE o.id IS NOT NULL), 0)::NUMERIC AS refund_amount,
    COALESCE(SUM(
      oio.price * GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
    ) FILTER (WHERE o.id IS NOT NULL), 0)::NUMERIC AS total_revenue
  FROM public.menu_extra_options meo
  JOIN public.menu_extras me ON me.id = meo.extra_id
  LEFT JOIN public.order_item_options oio ON oio.menu_extra_option_id = meo.id
  LEFT JOIN public.order_items oi ON oi.id = oio.order_item_id
  LEFT JOIN public.orders o
    ON o.id = oi.order_id
   AND o.status = 'paid'
   AND o.outlet_id = p_outlet_id
   AND (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE BETWEEN p_date_from AND p_date_to
  WHERE me.outlet_id = p_outlet_id
  GROUP BY meo.id;
$$;

REVOKE ALL ON FUNCTION public.report_extra_option_sales_v2(UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_extra_option_sales_v2(UUID, DATE, DATE) TO authenticated;

COMMENT ON FUNCTION public.report_extra_option_sales_v2(UUID, DATE, DATE) IS
  'Laporan penjualan opsi extra: qty bruto, refund, omzet bruto, refund, dan omzet bersih.';

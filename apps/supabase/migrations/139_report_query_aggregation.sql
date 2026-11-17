-- 139_report_query_aggregation.sql
-- Kurangi data yang dikirim ke Owner Panel dengan mengagregasi laporan di
-- database. Data transaksi tidak dihapus; yang berubah hanya bentuk response.
--
-- View laporan lama tetap dipertahankan karena dipakai mobile dan ekspor.
-- Fungsi di bawah dipakai oleh panel untuk kebutuhan yang memang sudah berupa
-- total (breakdown menu/kategori/departemen, pajak, extra, dan kartu summary).

CREATE OR REPLACE FUNCTION public.report_top_menu_items(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE,
  p_limit INTEGER DEFAULT 8
)
RETURNS TABLE (
  outlet_id UUID,
  menu_item_id UUID,
  menu_item_name TEXT,
  category_name TEXT,
  qty_sold BIGINT,
  total_revenue NUMERIC,
  sale_date TEXT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    CASE WHEN p_outlet_id IS NULL THEN NULL::UUID ELSE p_outlet_id END,
    CASE WHEN p_outlet_id IS NULL THEN NULL::UUID ELSE (array_agg(v.menu_item_id))[1] END,
    v.menu_item_name,
    v.category_name,
    SUM(v.qty_sold)::BIGINT,
    SUM(v.total_revenue)::NUMERIC,
    p_date_from::TEXT
  FROM public.v_top_menu_items v
  WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
    AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  GROUP BY v.menu_item_name, v.category_name
  ORDER BY SUM(v.qty_sold) DESC, SUM(v.total_revenue) DESC, v.menu_item_name
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 8), 100));
$$;

CREATE OR REPLACE FUNCTION public.report_category_sales(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  outlet_id UUID,
  category_id UUID,
  category_name TEXT,
  sale_date TEXT,
  qty_sold BIGINT,
  total_orders BIGINT,
  total_revenue NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    CASE WHEN p_outlet_id IS NULL THEN NULL::UUID ELSE p_outlet_id END,
    NULL::UUID,
    COALESCE(v.category_name, 'Tanpa Kategori'),
    p_date_from::TEXT,
    SUM(v.qty_sold)::BIGINT,
    SUM(COALESCE(v.total_orders, 0))::BIGINT,
    SUM(v.total_revenue)::NUMERIC
  FROM public.v_category_sales v
  WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
    AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  GROUP BY COALESCE(v.category_name, 'Tanpa Kategori')
  ORDER BY SUM(v.total_revenue) DESC, COALESCE(v.category_name, 'Tanpa Kategori');
$$;

CREATE OR REPLACE FUNCTION public.report_department_sales(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  outlet_id UUID,
  department_id UUID,
  department_name TEXT,
  color TEXT,
  sale_date TEXT,
  total_orders BIGINT,
  qty_sold BIGINT,
  total_revenue NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    CASE WHEN p_outlet_id IS NULL THEN NULL::UUID ELSE p_outlet_id END,
    NULL::UUID,
    COALESCE(v.department_name, 'Tanpa Departemen'),
    MIN(v.color),
    p_date_from::TEXT,
    SUM(v.total_orders)::BIGINT,
    SUM(v.qty_sold)::BIGINT,
    SUM(v.total_revenue)::NUMERIC
  FROM public.v_department_sales v
  WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
    AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  GROUP BY COALESCE(v.department_name, 'Tanpa Departemen')
  ORDER BY SUM(v.total_revenue) DESC, COALESCE(v.department_name, 'Tanpa Departemen');
$$;

CREATE OR REPLACE FUNCTION public.report_menu_sales(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  outlet_id UUID,
  menu_item_id UUID,
  menu_name TEXT,
  price NUMERIC,
  category_name TEXT,
  department_name TEXT,
  sale_date TEXT,
  qty_sold BIGINT,
  total_revenue NUMERIC,
  order_count BIGINT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    v.outlet_id,
    v.menu_item_id,
    v.menu_name,
    MAX(v.price)::NUMERIC,
    MIN(v.category_name),
    MIN(v.department_name),
    p_date_from::TEXT,
    SUM(v.qty_sold)::BIGINT,
    SUM(v.total_revenue)::NUMERIC,
    SUM(v.order_count)::BIGINT
  FROM public.v_menu_sales v
  WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
    AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  GROUP BY v.outlet_id, v.menu_item_id, v.menu_name
  ORDER BY SUM(v.total_revenue) DESC, v.menu_name;
$$;

CREATE OR REPLACE FUNCTION public.report_tax_sales(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE,
  p_period TEXT DEFAULT 'hari'
)
RETURNS TABLE (
  outlet_id UUID,
  sale_date TEXT,
  total_orders BIGINT,
  gross_revenue NUMERIC,
  total_discount NUMERIC,
  total_tax NUMERIC,
  total_service_charge NUMERIC,
  net_revenue NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF p_period NOT IN ('hari', 'bulan', 'tahun') THEN
    RAISE EXCEPTION 'Periode laporan tidak valid' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH grouped AS (
    SELECT
      v.outlet_id,
      CASE p_period
        WHEN 'tahun' THEN to_char(date_trunc('year', v.sale_date::DATE), 'YYYY-MM-DD')
        WHEN 'bulan' THEN to_char(date_trunc('month', v.sale_date::DATE), 'YYYY-MM-DD')
        ELSE v.sale_date
      END AS period_date,
      SUM(v.total_orders)::BIGINT AS orders,
      SUM(v.gross_revenue)::NUMERIC AS gross,
      SUM(v.total_discount)::NUMERIC AS discount,
      SUM(v.total_tax)::NUMERIC AS tax,
      SUM(v.total_service_charge)::NUMERIC AS service,
      SUM(v.net_revenue)::NUMERIC AS net
    FROM public.v_tax_report v
    WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
      AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
    GROUP BY v.outlet_id,
      CASE p_period
        WHEN 'tahun' THEN to_char(date_trunc('year', v.sale_date::DATE), 'YYYY-MM-DD')
        WHEN 'bulan' THEN to_char(date_trunc('month', v.sale_date::DATE), 'YYYY-MM-DD')
        ELSE v.sale_date
      END
  )
  SELECT g.outlet_id, g.period_date, g.orders, g.gross, g.discount, g.tax, g.service, g.net
  FROM grouped g
  ORDER BY g.period_date DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.report_extra_option_sales(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  option_id UUID,
  qty_selected BIGINT,
  total_revenue NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    v.option_id,
    SUM(v.qty_selected)::BIGINT,
    SUM(v.total_revenue)::NUMERIC
  FROM public.v_extra_option_sales v
  WHERE v.outlet_id = p_outlet_id
    AND v.sale_date IS NOT NULL
    AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  GROUP BY v.option_id;
$$;

CREATE OR REPLACE FUNCTION public.report_order_status_summary(
  p_outlet_id UUID,
  p_status public.order_status,
  p_date_from TIMESTAMPTZ,
  p_date_to TIMESTAMPTZ,
  p_order_type public.order_type DEFAULT NULL,
  p_search TEXT DEFAULT NULL
)
RETURNS TABLE (
  total_orders BIGINT,
  total_amount NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    COUNT(*)::BIGINT,
    COALESCE(SUM(o.total_amount), 0)::NUMERIC
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.status = p_status
    AND CASE p_status
      WHEN 'void' THEN o.voided_at
      WHEN 'cancelled' THEN o.cancelled_at
      ELSE o.updated_at
    END BETWEEN p_date_from AND p_date_to
    AND (p_order_type IS NULL OR o.order_type = p_order_type)
    AND (
      NULLIF(btrim(p_search), '') IS NULL
      OR o.order_number ILIKE '%' || btrim(p_search) || '%'
    );
$$;

CREATE OR REPLACE FUNCTION public.report_expense_summary(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  total_expenses NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(e.amount), 0)::NUMERIC
  FROM public.expenses e
  WHERE (p_outlet_id IS NULL OR e.outlet_id = p_outlet_id)
    AND e.expense_date BETWEEN p_date_from AND p_date_to;
$$;

REVOKE ALL ON FUNCTION public.report_top_menu_items(UUID, DATE, DATE, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_category_sales(UUID, DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_department_sales(UUID, DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_menu_sales(UUID, DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_tax_sales(UUID, DATE, DATE, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_extra_option_sales(UUID, DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_order_status_summary(UUID, public.order_status, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_expense_summary(UUID, DATE, DATE) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.report_top_menu_items(UUID, DATE, DATE, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_category_sales(UUID, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_department_sales(UUID, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_menu_sales(UUID, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_tax_sales(UUID, DATE, DATE, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_extra_option_sales(UUID, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_order_status_summary(UUID, public.order_status, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_expense_summary(UUID, DATE, DATE) TO authenticated;

COMMENT ON FUNCTION public.report_top_menu_items(UUID, DATE, DATE, INTEGER) IS
  'Server-side top menu aggregation for Owner Panel; returns only ranked rows.';
COMMENT ON FUNCTION public.report_order_status_summary(UUID, public.order_status, TIMESTAMPTZ, TIMESTAMPTZ, public.order_type, TEXT) IS
  'Server-side count and amount summary for void/cancelled reports.';

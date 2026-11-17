-- 180_dashboard_range_consistency.sql
--
-- Satu sumber kebenaran untuk metrik dashboard pada rentang tanggal bebas.
-- Sebelumnya dashboard menghitung laba sebagai penjualan kotor - pengeluaran,
-- sehingga diskon, refund, dan HPP tidak ikut dikurangkan. Fungsi ini memakai
-- sumber yang sama dengan v_profit_loss dan tetap mencakup data yang sudah
-- dipindahkan ke arsip.

CREATE OR REPLACE FUNCTION public.report_profit_loss_range(
  p_outlet_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS TABLE (
  gross_revenue NUMERIC,
  total_discount NUMERIC,
  total_refund NUMERIC,
  net_revenue NUMERIC,
  cost_of_goods NUMERIC,
  gross_profit NUMERIC,
  total_expenses NUMERIC,
  net_profit NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH revenue AS (
    SELECT
      COALESCE(SUM(v.gross_revenue), 0)::NUMERIC AS gross_revenue,
      COALESCE(SUM(v.total_discount), 0)::NUMERIC AS total_discount,
      COALESCE(SUM(
        GREATEST(
          v.gross_revenue - v.total_discount + v.total_tax
            + v.total_service_charge - v.net_revenue,
          0
        )
      ), 0)::NUMERIC AS total_refund,
      COALESCE(SUM(v.net_revenue), 0)::NUMERIC AS net_revenue
    FROM public.v_daily_sales v
    WHERE (p_outlet_id IS NULL OR v.outlet_id = p_outlet_id)
      AND v.sale_date::DATE BETWEEN p_date_from AND p_date_to
  ), live_hpp AS (
    SELECT COALESCE(SUM(h.hpp_total), 0)::NUMERIC AS amount
    FROM public.v_order_hpp h
    WHERE h.status = 'paid'
      AND (p_outlet_id IS NULL OR h.outlet_id = p_outlet_id)
      AND (h.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
        BETWEEN p_date_from AND p_date_to
  ), archived_hpp AS (
    SELECT COALESCE(SUM(s.cogs), 0)::NUMERIC AS amount
    FROM public.sales_daily_summary s
    JOIN public.transaction_archive_manifest m
      ON m.outlet_id = s.outlet_id
     AND m.business_date = s.sales_date
    WHERE (p_outlet_id IS NULL OR s.outlet_id = p_outlet_id)
      AND s.sales_date BETWEEN p_date_from AND p_date_to
  ), operating_expenses AS (
    SELECT COALESCE(SUM(e.amount), 0)::NUMERIC AS amount
    FROM public.expenses e
    WHERE (p_outlet_id IS NULL OR e.outlet_id = p_outlet_id)
      AND e.expense_date BETWEEN p_date_from AND p_date_to
      AND e.category <> 'bahan_baku'
  ), totals AS (
    SELECT
      r.gross_revenue,
      r.total_discount,
      r.total_refund,
      r.net_revenue,
      (lh.amount + ah.amount)::NUMERIC AS cost_of_goods,
      oe.amount::NUMERIC AS total_expenses
    FROM revenue r
    CROSS JOIN live_hpp lh
    CROSS JOIN archived_hpp ah
    CROSS JOIN operating_expenses oe
  )
  SELECT
    t.gross_revenue,
    t.total_discount,
    t.total_refund,
    t.net_revenue,
    t.cost_of_goods,
    (t.net_revenue - t.cost_of_goods)::NUMERIC AS gross_profit,
    t.total_expenses,
    (t.net_revenue - t.cost_of_goods - t.total_expenses)::NUMERIC AS net_profit
  FROM totals t
  WHERE p_date_from IS NOT NULL
    AND p_date_to IS NOT NULL
    AND p_date_from <= p_date_to;
$$;

-- Ringkasan pesanan aktif tidak boleh bergantung pada daftar UI yang dibatasi
-- 50 baris. Query ini hanya mengirim agregat sehingga tetap ringan.
CREATE OR REPLACE FUNCTION public.report_active_order_summary(
  p_outlet_id UUID
)
RETURNS TABLE (
  total_orders BIGINT,
  total_amount NUMERIC,
  dine_in_orders BIGINT,
  takeaway_orders BIGINT,
  self_order_orders BIGINT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    COUNT(*)::BIGINT,
    COALESCE(SUM(o.total_amount), 0)::NUMERIC,
    COUNT(*) FILTER (WHERE o.order_type = 'dine_in')::BIGINT,
    COUNT(*) FILTER (WHERE o.order_type = 'takeaway')::BIGINT,
    COUNT(*) FILTER (WHERE o.order_type = 'self_order')::BIGINT
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.status IN ('confirmed', 'preparing', 'ready');
$$;

REVOKE ALL ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_active_order_summary(UUID)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_active_order_summary(UUID)
  TO authenticated;

COMMENT ON FUNCTION public.report_profit_loss_range(UUID, DATE, DATE) IS
  'Laba-rugi untuk rentang tanggal bebas; mencakup transaksi live dan arsip.';
COMMENT ON FUNCTION public.report_active_order_summary(UUID) IS
  'Agregat ringan semua order aktif tanpa batas pagination daftar UI.';

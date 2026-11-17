-- 203_rollback_shift_summary_payments_fallback.sql
--
-- Rollback korektif untuk migration 202.
-- Memulihkan:
--   1. v_shift_summary dengan pengurangan refund dan dukungan arsip;
--   2. wrapper get_shift_close_report yang menyembunyikan rincian kas/expense
--      dari role kasir.
--
-- Migration 202 sudah melakukan backfill payments.shift_id. Nilai tersebut
-- sengaja tidak dikosongkan karena tidak ada penanda yang aman untuk
-- membedakan nilai hasil backfill dari nilai yang memang sudah ada sebelumnya.

CREATE OR REPLACE VIEW public.v_shift_summary AS
WITH live_paid AS (
  SELECT o.shift_id,
    COUNT(*)::INTEGER AS paid_orders
  FROM public.orders o
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), live_payment AS (
  SELECT o.shift_id,
    COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'cash'), 0)::NUMERIC AS cash_received,
    COALESCE(SUM(p.amount) FILTER (WHERE p.method <> 'cash'), 0)::NUMERIC AS non_cash_received
  FROM public.orders o
  JOIN public.payments p ON p.order_id = o.id
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), live_refund AS (
  SELECT o.shift_id,
    COALESCE(SUM(r.amount) FILTER (WHERE r.method = 'cash'), 0)::NUMERIC AS cash_refund,
    COALESCE(SUM(r.amount) FILTER (WHERE r.method <> 'cash'), 0)::NUMERIC AS non_cash_refund
  FROM public.orders o
  JOIN public.refunds r ON r.order_id = o.id
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), archive_paid AS (
  SELECT a.shift_id, COUNT(*)::INTEGER AS paid_orders
  FROM public.transaction_archive_orders a
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), archive_payment AS (
  SELECT a.shift_id,
    COALESCE(SUM((p.value->>'amount')::NUMERIC)
      FILTER (WHERE p.value->>'method' = 'cash'), 0) AS cash_received,
    COALESCE(SUM((p.value->>'amount')::NUMERIC)
      FILTER (WHERE p.value->>'method' <> 'cash'), 0) AS non_cash_received
  FROM public.transaction_archive_orders a
  CROSS JOIN LATERAL jsonb_array_elements(a.payments) p(value)
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), archive_refund AS (
  SELECT a.shift_id,
    COALESCE(SUM((r.value->>'amount')::NUMERIC)
      FILTER (WHERE r.value->>'method' = 'cash'), 0) AS cash_refund,
    COALESCE(SUM((r.value->>'amount')::NUMERIC)
      FILTER (WHERE r.value->>'method' <> 'cash'), 0) AS non_cash_refund
  FROM public.transaction_archive_orders a
  CROSS JOIN LATERAL jsonb_array_elements(a.refunds) r(value)
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), combined AS (
  SELECT shift_id, paid_orders, 0::NUMERIC AS cash_received,
    0::NUMERIC AS non_cash_received, 0::NUMERIC AS cash_refund,
    0::NUMERIC AS non_cash_refund FROM live_paid
  UNION ALL
  SELECT shift_id, 0, cash_received, non_cash_received, 0, 0 FROM live_payment
  UNION ALL
  SELECT shift_id, 0, 0, 0, cash_refund, non_cash_refund FROM live_refund
  UNION ALL
  SELECT shift_id, paid_orders, 0, 0, 0, 0 FROM archive_paid
  UNION ALL
  SELECT shift_id, 0, cash_received, non_cash_received, 0, 0 FROM archive_payment
  UNION ALL
  SELECT shift_id, 0, 0, 0, cash_refund, non_cash_refund FROM archive_refund
), totals AS (
  SELECT shift_id,
    SUM(paid_orders)::INTEGER AS paid_orders,
    (SUM(cash_received) - SUM(cash_refund))::NUMERIC(14,2) AS cash_received,
    (SUM(non_cash_received) - SUM(non_cash_refund))::NUMERIC(14,2) AS non_cash_received
  FROM combined
  GROUP BY shift_id
)
SELECT s.id AS shift_id, s.outlet_id,
  COALESCE(t.cash_received, 0)::NUMERIC(14,2) AS cash_received,
  COALESCE(t.non_cash_received, 0)::NUMERIC(14,2) AS non_cash_received,
  COALESCE(t.paid_orders, 0)::INTEGER AS paid_orders
FROM public.shifts s
LEFT JOIN totals t ON t.shift_id = s.id;

GRANT SELECT ON public.v_shift_summary TO authenticated;
ALTER VIEW public.v_shift_summary SET (security_invoker = on);
COMMENT ON VIEW public.v_shift_summary IS
  'Ringkasan shift dengan payment dan refund live/arsip.';

CREATE OR REPLACE FUNCTION public.get_shift_close_report(p_shift_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  v_result := public.get_shift_close_report_management_impl(p_shift_id);

  IF NOT COALESCE(public.is_owner(), false)
     AND v_role NOT IN ('admin', 'manajer') THEN
    v_result := v_result || jsonb_build_object(
      'cash_in', 0,
      'cash_out', 0,
      'expenses', '[]'::JSONB
    );
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_shift_close_report(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shift_close_report(UUID)
  TO authenticated;

COMMENT ON FUNCTION public.get_shift_close_report(UUID) IS
  'Laporan tutup shift dengan rincian kas/expense terbatas untuk manajemen.';

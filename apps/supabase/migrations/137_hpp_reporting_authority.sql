-- 137_hpp_reporting_authority.sql
-- Menjadikan HPP server sebagai sumber laporan mobile dan owner panel.
-- Item yang direfund tidak lagi dihitung sebagai barang terjual.

-- v_profit_loss BERGANTUNG pada v_order_hpp (versi baru di bawah), jadi ia harus
-- di-drop LEBIH DULU — kalau tidak, DROP v_order_hpp gagal dengan
-- "cannot drop ... other objects depend on it" saat migration di-run ulang atau
-- di database yang v_profit_loss-nya sudah menunjuk v_order_hpp. Urutan drop
-- mengikuti arah ketergantungan (dependen dulu).
DROP VIEW IF EXISTS public.v_profit_loss;
DROP VIEW IF EXISTS public.v_order_hpp;
CREATE VIEW public.v_order_hpp AS
SELECT
  oi.order_id,
  o.outlet_id,
  o.created_at,
  o.status,
  COALESCE(SUM(
    GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
    * er.qty_per_portion
    * i.cost_per_unit
  ), 0)::NUMERIC(14,2) AS hpp_total
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.v_effective_recipe er ON er.menu_item_id = oi.menu_item_id
LEFT JOIN public.ingredients i ON i.id = er.ingredient_id
GROUP BY oi.order_id, o.outlet_id, o.created_at, o.status;

GRANT SELECT ON public.v_order_hpp TO authenticated;
ALTER VIEW public.v_order_hpp SET (security_invoker = on);

COMMENT ON VIEW public.v_order_hpp IS
  'HPP per order dari resep efektif dan weighted average cost. Qty refund '
  'dikeluarkan dari HPP agar laba kotor mengikuti penjualan bersih.';

-- v_profit_loss sebelumnya memakai expenses kategori bahan_baku sebagai HPP.
-- Itu adalah arus pembelian/pengeluaran, bukan biaya barang yang benar-benar
-- terjual. HPP kini mengikuti item paid pada v_order_hpp.
DROP VIEW IF EXISTS public.v_profit_loss;
CREATE VIEW public.v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    o.outlet_id,
    TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(o.subtotal) AS gross_revenue,
    SUM(o.discount_amount) AS total_discount,
    COALESCE(SUM(rf.refund), 0) AS total_refund,
    SUM(o.total_amount - COALESCE(rf.refund, 0)) AS net_revenue
  FROM public.orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund
    FROM public.refunds
    GROUP BY order_id
  ) rf ON rf.order_id = o.id
  WHERE o.status = 'paid'
  GROUP BY o.outlet_id, TO_CHAR(o.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
),
monthly_hpp AS (
  SELECT
    outlet_id,
    TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(hpp_total) AS cost_of_goods
  FROM public.v_order_hpp
  WHERE status = 'paid'
  GROUP BY outlet_id, TO_CHAR(created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
),
monthly_expenses AS (
  SELECT
    outlet_id,
    TO_CHAR(expense_date, 'YYYY-MM') AS month,
    COALESCE(SUM(amount) FILTER (WHERE category <> 'bahan_baku'), 0) AS total_expenses
  FROM public.expenses
  GROUP BY outlet_id, TO_CHAR(expense_date, 'YYYY-MM')
),
all_periods AS (
  SELECT outlet_id, month FROM monthly_revenue
  UNION
  SELECT outlet_id, month FROM monthly_hpp
  UNION
  SELECT outlet_id, month FROM monthly_expenses
)
SELECT
  p.outlet_id,
  p.month,
  COALESCE(r.gross_revenue, 0)::numeric AS gross_revenue,
  COALESCE(r.total_discount, 0)::numeric AS total_discount,
  COALESCE(r.total_refund, 0)::numeric AS total_refund,
  COALESCE(r.net_revenue, 0)::numeric AS net_revenue,
  COALESCE(h.cost_of_goods, 0)::numeric AS cost_of_goods,
  (COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0))::numeric AS gross_profit,
  COALESCE(e.total_expenses, 0)::numeric AS total_expenses,
  ((COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0))
    - COALESCE(e.total_expenses, 0))::numeric AS net_profit
FROM all_periods p
LEFT JOIN monthly_revenue r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_hpp h ON h.outlet_id = p.outlet_id AND h.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;

GRANT SELECT ON public.v_profit_loss TO authenticated;
ALTER VIEW public.v_profit_loss SET (security_invoker = on);

-- 202_fix_shift_summary_payments_fallback.sql
--
-- Laporan Tutup Kasir tampil semua Rp0 karena v_shift_summary dan
-- get_shift_close_report masih menggabungkan payments/refunds via
-- orders.shift_id dengan filter 'status = paid' yang ketat. Karena
-- record_pos_payment_with_context menyimpan shift_id per payment (bukan
-- hanya di order), join via orders.shift_id membuang:
--   * split bill yang baru lunas setelah window ditelusuri;
--   * order lama yang dibuat sebelum till dibuka (orders.shift_id NULL);
--   * pembayaran order lintas-kasir (shift payment ≠ shift order).
--
-- Perbaikannya:
--   1. Backfill payments.shift_id dari orders.shift_id untuk data historis
--      yang dibuat sebelum migrasi 165 (aman: shift_id nullable, trigger
--      guard_payment_shift hanya menolak update ke shift yang sudah tutup
--      setelah paid_at).
--   2. Rewrite v_shift_summary agar agregasi mengikuti payments.shift_id
--      dengan fallback ke orders.shift_id, sehingga data lama + baru
--      konsisten.
--   3. Tulis ulang get_shift_close_report dengan sumber payments.shift_id
--      (fallback orders.shift_id) untuk payment_methods, produk, pajak,
--      service, diskon, refund, dan void item — supaya ringkasan dan
--      detail per shift cocok.

-- ── 1. Backfill payments.shift_id ─────────────────────────────────────────
UPDATE public.payments p
SET shift_id = o.shift_id
FROM public.orders o
WHERE o.id = p.order_id
  AND p.shift_id IS NULL
  AND o.shift_id IS NOT NULL;

-- ── 2. v_shift_summary baru ───────────────────────────────────────────────
DROP VIEW IF EXISTS public.v_shift_summary;
CREATE VIEW public.v_shift_summary AS
WITH shift_payments AS (
  -- Pembayaran yang tercatat pada till (payments.shift_id), termasuk
  -- split bill dan payment order lintas-kasir.
  SELECT p.shift_id,
    p.method,
    p.amount,
    p.order_id
  FROM public.payments p
  WHERE p.shift_id IS NOT NULL
  UNION ALL
  -- Fallback untuk payment lama sebelum migrasi 165: ambil dari order
  -- yang shift_id-nya cocok dengan shift ini, selama payment belum
  -- teratribusikan.
  SELECT o.shift_id AS shift_id,
    p.method,
    p.amount,
    p.order_id
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE p.shift_id IS NULL
    AND o.shift_id IS NOT NULL
), paid_orders AS (
  -- paid_orders dihitung dari order yang lunas, mengikuti shift_id order
  -- atau fallback ke shift payment pertama (untuk split di order lama).
  SELECT o.id, COALESCE(o.shift_id, first_payment.shift_id) AS shift_id
  FROM public.orders o
  LEFT JOIN LATERAL (
    SELECT p.shift_id
    FROM public.payments p
    WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
    ORDER BY p.paid_at ASC
    LIMIT 1
  ) first_payment ON true
  WHERE o.status = 'paid'
), aggregates AS (
  SELECT
    sp.shift_id,
    COALESCE(SUM(sp.amount) FILTER (WHERE sp.method = 'cash'),  0)::NUMERIC(14,2) AS cash_received,
    COALESCE(SUM(sp.amount) FILTER (WHERE sp.method <> 'cash'), 0)::NUMERIC(14,2) AS non_cash_received
  FROM shift_payments sp
  GROUP BY sp.shift_id
), paid_counts AS (
  SELECT po.shift_id,
    COUNT(*)::INTEGER AS paid_orders
  FROM paid_orders po
  GROUP BY po.shift_id
)
SELECT
  s.id AS shift_id,
  s.outlet_id,
  COALESCE(a.cash_received, 0)::NUMERIC(14,2) AS cash_received,
  COALESCE(a.non_cash_received, 0)::NUMERIC(14,2) AS non_cash_received,
  COALESCE(pc.paid_orders, 0)::INTEGER AS paid_orders
FROM public.shifts s
LEFT JOIN aggregates  a  ON a.shift_id  = s.id
LEFT JOIN paid_counts pc ON pc.shift_id = s.id;

GRANT SELECT ON public.v_shift_summary TO authenticated;
ALTER VIEW public.v_shift_summary SET (security_invoker = on);
COMMENT ON VIEW public.v_shift_summary IS
  'Total payment per shift via payments.shift_id (fallback orders.shift_id) '
  'untuk payment yang dibuat sebelum migrasi 165. paid_orders mengikuti '
  'shift_id order dengan fallback shift payment pertama.';

-- ── 3. get_shift_close_report versi perbaikan ─────────────────────────────
-- Versi ini menggantikan sumber agregasi dari orders.shift_id ke
-- payments.shift_id (fallback orders.shift_id) sehingga cocok dengan
-- model data baru dan view ringkasan di atas.

CREATE OR REPLACE FUNCTION public.get_shift_close_report(p_shift_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_outlet public.outlets%ROWTYPE;
  v_cashier TEXT;
  v_payments JSONB;
  v_products JSONB;
  v_expenses JSONB;
  v_result JSONB;
BEGIN
  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_shift.end_time IS NULL THEN
    RAISE EXCEPTION 'Shift belum ditutup' USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR v_shift.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Tidak berizin melihat laporan shift ini'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_outlet
  FROM public.outlets
  WHERE id = v_shift.outlet_id;

  SELECT full_name INTO v_cashier
  FROM public.profiles
  WHERE id = v_shift.kasir_id;

  -- payment_net: agregasi per metode, sumber payments.shift_id dengan
  -- fallback ke orders.shift_id agar payment historis tetap masuk.
  WITH payment_net AS (
    SELECT method, SUM(amount) AS amount
    FROM (
      SELECT p.method, p.amount
      FROM public.payments p
      WHERE p.shift_id = p_shift_id
      UNION ALL
      -- Fallback: payment lama yang shift_id masih null tapi order-nya
      -- milik shift ini.
      SELECT p.method, p.amount
      FROM public.payments p
      JOIN public.orders o ON o.id = p.order_id
      WHERE p.shift_id IS NULL
        AND o.shift_id = p_shift_id
      UNION ALL
      SELECT r.method, -r.amount
      FROM public.refunds r
      JOIN public.orders o ON o.id = r.order_id
      WHERE o.shift_id = p_shift_id
    ) x
    GROUP BY method
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('method', method::TEXT, 'amount', amount)
      ORDER BY method::TEXT
    ),
    '[]'::JSONB
  )
  INTO v_payments
  FROM payment_net;

  -- product_net: agregasi per produk dari order yang lunas, difilter
  -- via orders.shift_id dengan fallback ke payment.shift_id pertama.
  WITH order_shift AS (
    SELECT o.id,
      COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC
        LIMIT 1
      )) AS effective_shift_id
    FROM public.orders o
  ), product_net AS (
    SELECT
      COALESCE(mi.name, 'Menu') AS name,
      SUM(
        GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
      )::INTEGER AS qty,
      SUM(
        GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
        * oi.unit_price
      ) AS amount
    FROM order_shift os
    JOIN public.order_items oi ON oi.order_id = os.id
    LEFT JOIN public.orders o ON o.id = os.id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE os.effective_shift_id = p_shift_id
      AND o.status = 'paid'
    GROUP BY COALESCE(mi.name, 'Menu')
    HAVING SUM(
      GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
    ) > 0
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('name', name, 'quantity', qty, 'amount', amount)
      ORDER BY name
    ),
    '[]'::JSONB
  )
  INTO v_products
  FROM product_net;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', cm.id,
        'category', COALESCE(e.category::TEXT, 'lain_lain'),
        'description', COALESCE(
          NULLIF(btrim(e.description), ''),
          NULLIF(btrim(cm.note), ''),
          'Pengeluaran kasir'
        ),
        'amount', cm.amount,
        'created_at', cm.created_at
      )
      ORDER BY cm.created_at, cm.id
    ),
    '[]'::JSONB
  )
  INTO v_expenses
  FROM public.cash_movements cm
  LEFT JOIN public.expenses e ON e.cash_movement_id = cm.id
  WHERE cm.shift_id = p_shift_id
    AND cm.type = 'out';

  SELECT jsonb_build_object(
    'shift_id', v_shift.id,
    'outlet_id', v_shift.outlet_id,
    'outlet', jsonb_build_object(
      'name', COALESCE(v_outlet.name, ''),
      'address', COALESCE(v_outlet.address, ''),
      'phone', COALESCE(v_outlet.phone, ''),
      'city', COALESCE(v_outlet.city, ''),
      'settings', COALESCE(v_outlet.settings, '{}'::JSONB)
    ),
    'cashier_id', v_shift.kasir_id,
    'cashier_name', COALESCE(v_cashier, 'Kasir'),
    'opened_at', v_shift.start_time,
    'closed_at', v_shift.end_time,
    'opening_cash', v_shift.opening_cash,
    'closing_cash', v_shift.closing_cash,
    'expected_cash', v_shift.expected_cash,
    'cash_difference', v_shift.cash_difference,
    'cash_received', COALESCE((
      SELECT SUM((x->>'amount')::NUMERIC)
      FROM jsonb_array_elements(v_payments) x
      WHERE x->>'method' = 'cash'
    ), 0),
    'non_cash_received', COALESCE((
      SELECT SUM((x->>'amount')::NUMERIC)
      FROM jsonb_array_elements(v_payments) x
      WHERE x->>'method' <> 'cash'
    ), 0),
    'total_receipts', COALESCE((
      SELECT SUM((x->>'amount')::NUMERIC)
      FROM jsonb_array_elements(v_payments) x
    ), 0),
    'tax_total', COALESCE((
      SELECT SUM(o.tax_amount)
      FROM public.orders o
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
        AND o.status = 'paid'
    ), 0),
    'service_charge_total', COALESCE((
      SELECT SUM(o.service_charge)
      FROM public.orders o
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
        AND o.status = 'paid'
    ), 0),
    'discount_total', COALESCE((
      SELECT SUM(o.discount_amount + COALESCE(o.loyalty_discount, 0))
      FROM public.orders o
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
        AND o.status = 'paid'
    ), 0),
    'refund_total', COALESCE((
      SELECT SUM(r.amount)
      FROM public.refunds r
      JOIN public.orders o ON o.id = r.order_id
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
    ), 0),
    'cash_in', COALESCE((
      SELECT SUM(cm.amount)
      FROM public.cash_movements cm
      WHERE cm.shift_id = p_shift_id AND cm.type = 'in'
    ), 0),
    'cash_out', COALESCE((
      SELECT SUM(cm.amount)
      FROM public.cash_movements cm
      WHERE cm.shift_id = p_shift_id AND cm.type = 'out'
    ), 0),
    'expenses', v_expenses,
    'completed_transactions', (
      SELECT COUNT(*)
      FROM public.orders o
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
        AND o.status = 'paid'
    ),
    'unpaid_transactions', (
      SELECT COUNT(*)
      FROM public.orders o
      WHERE COALESCE(o.shift_id, (
        SELECT p.shift_id FROM public.payments p
        WHERE p.order_id = o.id AND p.shift_id IS NOT NULL
        ORDER BY p.paid_at ASC LIMIT 1
      )) = p_shift_id
        AND o.status IN (
          'draft', 'confirmed', 'preparing', 'ready', 'served'
        )
    ),
    'void_item_quantity', COALESCE((
      SELECT SUM(v.quantity)
      FROM public.order_item_voids v
      WHERE v.shift_id = p_shift_id
    ), 0),
    'void_item_amount', COALESCE((
      SELECT SUM(v.amount)
      FROM public.order_item_voids v
      WHERE v.shift_id = p_shift_id
    ), 0),
    'payment_methods', v_payments,
    'products', v_products,
    'product_quantity', COALESCE((
      SELECT SUM((x->>'quantity')::INTEGER)
      FROM jsonb_array_elements(v_products) x
    ), 0),
    'notes', v_shift.notes
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_shift_close_report(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shift_close_report(UUID)
  TO authenticated;

COMMENT ON FUNCTION public.get_shift_close_report(UUID) IS
  'Snapshot tutup kasir: payment bersih per payment.shift_id (fallback '
  'orders.shift_id), rekonsiliasi laci, pengeluaran, produk, void, dan refund. '
  'Sumber pembayaran konsisten dengan v_shift_summary.';
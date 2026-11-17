-- 164_shift_close_expense_details.sql
--
-- Laporan tutup kasir sebelumnya hanya mengembalikan total cash_out. Akibatnya
-- struk tidak dapat menjelaskan uang keluar dipakai untuk apa. Tambahkan daftar
-- pengeluaran per shift dari cash_movements, diperkaya kategori/uraian expenses
-- yang otomatis dibuat oleh record_cash_movement (migration 150).

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

  SELECT * INTO v_outlet FROM public.outlets WHERE id = v_shift.outlet_id;
  SELECT full_name INTO v_cashier
  FROM public.profiles WHERE id = v_shift.kasir_id;

  WITH payment_net AS (
    SELECT method, SUM(amount) AS amount
    FROM (
      SELECT p.method, p.amount
      FROM public.payments p
      JOIN public.orders o ON o.id = p.order_id
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
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

  WITH product_net AS (
    SELECT
      COALESCE(mi.name, 'Menu') AS name,
      SUM(
        GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
      )::INTEGER AS qty,
      SUM(
        GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)
        * oi.unit_price
      ) AS amount
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE o.shift_id = p_shift_id
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
      SELECT SUM(o.tax_amount) FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ), 0),
    'service_charge_total', COALESCE((
      SELECT SUM(o.service_charge) FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ), 0),
    'discount_total', COALESCE((
      SELECT SUM(o.discount_amount + COALESCE(o.loyalty_discount, 0))
      FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ), 0),
    'refund_total', COALESCE((
      SELECT SUM(r.amount)
      FROM public.refunds r
      JOIN public.orders o ON o.id = r.order_id
      WHERE o.shift_id = p_shift_id
    ), 0),
    'cash_in', COALESCE((
      SELECT SUM(cm.amount) FROM public.cash_movements cm
      WHERE cm.shift_id = p_shift_id AND cm.type = 'in'
    ), 0),
    'cash_out', COALESCE((
      SELECT SUM(cm.amount) FROM public.cash_movements cm
      WHERE cm.shift_id = p_shift_id AND cm.type = 'out'
    ), 0),
    'expenses', v_expenses,
    'completed_transactions', (
      SELECT COUNT(*) FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ),
    'unpaid_transactions', (
      SELECT COUNT(*) FROM public.orders o
      WHERE o.shift_id = p_shift_id
        AND o.status IN (
          'draft', 'confirmed', 'preparing', 'ready', 'served'
        )
    ),
    'void_item_quantity', COALESCE((
      SELECT SUM(v.quantity) FROM public.order_item_voids v
      WHERE v.shift_id = p_shift_id
    ), 0),
    'void_item_amount', COALESCE((
      SELECT SUM(v.amount) FROM public.order_item_voids v
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
  'Snapshot laporan tutup kasir termasuk penerimaan, rekonsiliasi laci, '
  'rincian pengeluaran kasir, metode pembayaran, dan produk terjual.';

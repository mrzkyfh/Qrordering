-- 165_payment_shift_integrity.sql
--
-- Pembayaran sebelumnya hanya mewarisi orders.shift_id. Model itu kehilangan:
--   * pembayaran parsial pada order yang belum berstatus paid;
--   * pembayaran non-tunai self-order yang semula tidak memiliki shift;
--   * identitas shift penerima ketika order dibuat oleh kasir lain.
--
-- Simpan shift pada setiap payment, catat konteks + payment dalam satu RPC, dan
-- bentuk rekonsiliasi laci dari payment aktual (bukan status akhir order).

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS shift_id UUID
  REFERENCES public.shifts(id) ON DELETE SET NULL;

UPDATE public.payments p
SET shift_id = o.shift_id
FROM public.orders o
WHERE o.id = p.order_id
  AND p.shift_id IS NULL
  AND o.shift_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_payments_shift_paid
  ON public.payments(shift_id, paid_at);

COMMENT ON COLUMN public.payments.shift_id IS
  'Shift penerima pembayaran. Disimpan per payment agar split bill dan '
  'pembayaran order lintas-kasir tetap teratribusi dengan benar.';

-- Inti payment tidak diekspos ke role aplikasi. RPC publik lama meneruskan
-- shift order, sedangkan RPC atomik baru meneruskan shift penerima secara
-- eksplisit sejak INSERT (bukan memperbaikinya setelah INSERT).
CREATE OR REPLACE FUNCTION public.record_pos_payment_internal(
  p_order_id UUID,
  p_outlet_id UUID,
  p_payment_shift_id UUID,
  p_method public.payment_method,
  p_amount NUMERIC,
  p_reference_number TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_finalize BOOLEAN DEFAULT TRUE,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_payment_id UUID;
  v_paid NUMERIC;
  v_is_duplicate BOOLEAN := false;
  v_will_be_paid BOOLEAN := false;
BEGIN
  IF p_order_id IS NULL OR p_outlet_id IS NULL
     OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Order, outlet, dan nominal pembayaran wajib valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.outlet_id <> p_outlet_id THEN
    RAISE EXCEPTION 'Order tidak ditemukan di outlet tersebut'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir')
     OR NOT (
       COALESCE(public.is_owner(), false)
       OR v_order.outlet_id = public.auth_outlet_id()
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang membayar order ini'
      USING ERRCODE = '42501';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_payment_id
    FROM public.payments
    WHERE order_id = p_order_id
      AND idempotency_key = p_idempotency_key;
    v_is_duplicate := v_payment_id IS NOT NULL;
  END IF;

  IF v_order.status IN ('cancelled', 'void') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan' USING ERRCODE = '22023';
  END IF;
  IF v_order.status = 'paid' AND NOT v_is_duplicate THEN
    RAISE EXCEPTION 'Order sudah lunas' USING ERRCODE = '22023';
  END IF;

  IF v_is_duplicate AND v_order.status = 'paid' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.payments
    WHERE order_id = p_order_id;
    RETURN jsonb_build_object(
      'payment_id', v_payment_id,
      'paid_total', v_paid,
      'order_total', v_order.total_amount,
      'status', 'paid',
      'duplicate', true
    );
  END IF;

  PERFORM public.validate_order_financial_integrity(p_order_id);
  IF p_finalize THEN
    PERFORM public.settle_pos_order_adjustments(p_order_id);
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;
    PERFORM public.validate_order_financial_integrity(p_order_id);
  END IF;

  IF NOT v_is_duplicate THEN
    INSERT INTO public.payments(
      order_id,
      outlet_id,
      shift_id,
      method,
      amount,
      reference_number,
      paid_at,
      idempotency_key
    ) VALUES (
      p_order_id,
      p_outlet_id,
      COALESCE(p_payment_shift_id, v_order.shift_id),
      p_method,
      p_amount,
      p_reference_number,
      COALESCE(p_paid_at, now()),
      p_idempotency_key
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_payment_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM public.payments
  WHERE order_id = p_order_id;

  v_will_be_paid := p_finalize AND v_paid >= v_order.total_amount;
  IF v_will_be_paid THEN
    PERFORM set_config('app.order_status_mutation', 'on', true);
    UPDATE public.orders
    SET status = 'paid',
        updated_at = now()
    WHERE id = p_order_id
      AND status IN ('draft', 'confirmed', 'preparing', 'ready', 'served');
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'paid_total', v_paid,
    'order_total', v_order.total_amount,
    'status', CASE
      WHEN v_will_be_paid THEN 'paid'
      ELSE v_order.status::TEXT
    END,
    'duplicate', v_is_duplicate
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment_internal(
  UUID, UUID, UUID, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;

-- Signature lama tetap tersedia agar klien yang belum diperbarui tidak rusak.
CREATE OR REPLACE FUNCTION public.record_pos_payment(
  p_order_id UUID,
  p_outlet_id UUID,
  p_method public.payment_method,
  p_amount NUMERIC,
  p_reference_number TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_finalize BOOLEAN DEFAULT TRUE,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.record_pos_payment_internal(
    p_order_id,
    p_outlet_id,
    NULL,
    p_method,
    p_amount,
    p_reference_number,
    p_idempotency_key,
    p_finalize,
    p_paid_at
  )
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pos_payment(
  UUID, UUID, public.payment_method, NUMERIC, TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) TO authenticated;

-- Setelah payments memiliki shift_id, pagar integritas harus memvalidasi shift
-- pada payment itu sendiri. Versi lama hanya membaca orders.shift_id dan tidak
-- terpanggil ketika shift_id payment diubah.
CREATE OR REPLACE FUNCTION public.guard_payment_shift()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role  TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_order public.orders%ROWTYPE;
  v_shift public.shifts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = NEW.order_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.shift_id IS NULL THEN
    IF NEW.method::TEXT = 'cash' THEN
      RAISE EXCEPTION 'Pembayaran tunai wajib memakai till terbuka'
        USING ERRCODE = '22023';
    END IF;
    -- Klien lama masih boleh mencatat non-tunai tanpa shift. RPC baru selalu
    -- mengirim shift_id sehingga data baru tetap lengkap.
    RETURN NEW;
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = NEW.shift_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Till pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF v_shift.end_time IS NOT NULL AND NEW.paid_at > v_shift.end_time THEN
    RAISE EXCEPTION 'Till pembayaran sudah ditutup'
      USING ERRCODE = '22023';
  END IF;
  IF v_role IN ('manajer', 'kasir')
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya boleh menerima pembayaran pada till miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_payment_shift() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_guard_payment_shift ON public.payments;
CREATE TRIGGER trg_guard_payment_shift
  BEFORE INSERT OR UPDATE OF
    order_id, outlet_id, shift_id, method, paid_at
  ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.guard_payment_shift();

-- Atribusi order dan INSERT payment berada dalam transaksi database yang sama.
CREATE OR REPLACE FUNCTION public.record_pos_payment_with_context(
  p_order_id UUID,
  p_outlet_id UUID,
  p_shift_id UUID,
  p_force_order_shift BOOLEAN,
  p_method public.payment_method,
  p_amount NUMERIC,
  p_reference_number TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_finalize BOOLEAN DEFAULT TRUE,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_shift public.shifts%ROWTYPE;
  v_result JSONB;
  v_payment_id UUID;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  IF p_shift_id IS NULL THEN
    RAISE EXCEPTION 'Pembayaran wajib dihubungkan ke shift kasir'
      USING ERRCODE = '22023';
  END IF;
  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang menerima pembayaran'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Shift pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  IF v_shift.end_time IS NOT NULL
     AND COALESCE(p_paid_at, now()) > v_shift.end_time THEN
    RAISE EXCEPTION 'Shift pembayaran sudah ditutup'
      USING ERRCODE = '22023';
  END IF;
  IF v_role IN ('manajer', 'kasir')
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya boleh menerima pembayaran pada shift miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Order tidak ditemukan di outlet tersebut'
      USING ERRCODE = '22023';
  END IF;

  -- Hindari UPDATE metadata yang tak perlu. Ini penting untuk replay offline:
  -- order sudah dibuat dengan shift historis dan trigger memang menolak
  -- "memindahkan" order real-time ke shift yang telah ditutup.
  IF v_order.created_by IS NULL
     OR (
       COALESCE(p_force_order_shift, false)
       AND v_order.shift_id IS DISTINCT FROM p_shift_id
     ) THEN
    PERFORM public.assign_order_payment_context(
      p_order_id,
      p_shift_id,
      COALESCE(p_force_order_shift, false)
    );
  END IF;

  v_result := public.record_pos_payment_internal(
    p_order_id,
    p_outlet_id,
    p_shift_id,
    p_method,
    p_amount,
    p_reference_number,
    p_idempotency_key,
    p_finalize,
    p_paid_at
  );

  v_payment_id := NULLIF(v_result->>'payment_id', '')::UUID;
  IF v_payment_id IS NOT NULL THEN
    -- Payment baru selalu mengikuti shift penerima, bukan shift pembuat order.
    -- Retry lama hanya di-backfill bila atribusinya memang masih kosong.
    UPDATE public.payments
    SET shift_id = p_shift_id
    WHERE id = v_payment_id
      AND (
        NOT COALESCE((v_result->>'duplicate')::BOOLEAN, false)
        OR shift_id IS NULL
      );
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) TO authenticated;

COMMENT ON FUNCTION public.record_pos_payment_with_context(
  UUID, UUID, UUID, BOOLEAN, public.payment_method, NUMERIC,
  TEXT, TEXT, BOOLEAN, TIMESTAMPTZ
) IS
  'Mengatribusikan shift dan mencatat payment secara atomik; aman untuk split '
  'bill, self-order, retry idempoten, dan replay offline.';

CREATE OR REPLACE FUNCTION public.close_shift(
  p_shift_id UUID,
  p_closing_cash NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_cash_total NUMERIC := 0;
  v_refund_cash NUMERIC := 0;
  v_movement_net NUMERIC := 0;
  v_expected_cash NUMERIC := 0;
  v_cash_difference NUMERIC := 0;
BEGIN
  IF p_closing_cash IS NULL OR p_closing_cash < 0 THEN
    RAISE EXCEPTION 'Uang penutupan shift tidak valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_shift.end_time IS NOT NULL THEN
    RAISE EXCEPTION 'shift already closed' USING ERRCODE = '22023';
  END IF;

  -- Semua uang tunai yang benar-benar diterima dihitung, termasuk split bill
  -- pada order yang belum lunas.
  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM public.payments p
  WHERE p.shift_id = p_shift_id
    AND p.method = 'cash';

  SELECT COALESCE(SUM(r.amount), 0) INTO v_refund_cash
  FROM public.refunds r
  JOIN public.orders o ON o.id = r.order_id
  WHERE o.shift_id = p_shift_id
    AND r.method = 'cash';

  SELECT COALESCE(
    SUM(CASE WHEN cm.type = 'in' THEN cm.amount ELSE -cm.amount END),
    0
  )
  INTO v_movement_net
  FROM public.cash_movements cm
  WHERE cm.shift_id = p_shift_id;

  v_expected_cash :=
    v_shift.opening_cash + v_cash_total - v_refund_cash + v_movement_net;
  v_cash_difference := p_closing_cash - v_expected_cash;

  UPDATE public.shifts
  SET end_time = now(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

COMMENT ON FUNCTION public.close_shift(UUID, NUMERIC, TEXT) IS
  'Tutup shift memakai seluruh payment tunai per payment.shift_id, termasuk '
  'pembayaran parsial, dikurangi refund tunai dan ditambah net cash movement.';

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

  WITH payment_net AS (
    SELECT method, SUM(amount) AS amount
    FROM (
      SELECT p.method, p.amount
      FROM public.payments p
      WHERE p.shift_id = p_shift_id
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
      SELECT SUM(o.tax_amount)
      FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ), 0),
    'service_charge_total', COALESCE((
      SELECT SUM(o.service_charge)
      FROM public.orders o
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
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ),
    'unpaid_transactions', (
      SELECT COUNT(*)
      FROM public.orders o
      WHERE o.shift_id = p_shift_id
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
  'Snapshot tutup kasir: payment bersih per payment.shift_id termasuk split '
  'parsial, rekonsiliasi laci, pengeluaran, produk, void, dan refund.';

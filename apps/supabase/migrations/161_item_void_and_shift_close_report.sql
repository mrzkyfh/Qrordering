-- 161_item_void_and_shift_close_report.sql
--
-- 1. Void sebagian item untuk order yang BELUM lunas. Perubahan item, nilai
--    order, stok, persetujuan PIN, dan audit dilakukan dalam satu transaksi.
-- 2. Laporan tutup kasir dibentuk di server dari transaksi final agar angka
--    pada layar dan struk cetak memakai sumber data yang sama.

-- ── Jejak void item ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.order_item_voids (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  shift_id       UUID REFERENCES public.shifts(id) ON DELETE SET NULL,
  outlet_id      UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  order_item_id  UUID,
  menu_item_id   UUID REFERENCES public.menu_items(id) ON DELETE SET NULL,
  menu_name      TEXT NOT NULL,
  quantity       INTEGER NOT NULL CHECK (quantity > 0),
  unit_price     NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  amount         NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
  item_snapshot  JSONB NOT NULL DEFAULT '{}'::JSONB,
  reason         TEXT,
  voided_by      UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  approved_by    UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  voided_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_item_voids_order
  ON public.order_item_voids(order_id, voided_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_item_voids_shift
  ON public.order_item_voids(shift_id, voided_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_item_voids_outlet
  ON public.order_item_voids(outlet_id, voided_at DESC);

ALTER TABLE public.order_item_voids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "order_item_voids_select" ON public.order_item_voids;
CREATE POLICY "order_item_voids_select" ON public.order_item_voids
  FOR SELECT TO authenticated
  USING (
    COALESCE(public.is_owner(), false)
    OR outlet_id = public.auth_outlet_id()
  );

REVOKE INSERT, UPDATE, DELETE ON public.order_item_voids
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_item_voids TO authenticated;

COMMENT ON TABLE public.order_item_voids IS
  'Snapshot immutable item yang dibatalkan sebelum order lunas.';

-- Restore lama mengembalikan setiap transaksi usage tanpa memperhitungkan
-- return parsial. Setelah void item tersedia, cara itu dapat mengembalikan stok
-- dua kali saat sisa order kemudian di-void seluruhnya. Versi ini hanya
-- mengembalikan pemakaian BERSIH (usage - return) per bahan.
CREATE OR REPLACE FUNCTION public.restore_stock_for_order(p_order_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_net RECORD;
  v_ing public.ingredients%ROWTYPE;
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  IF NOT COALESCE(v_order.stock_deducted, false)
     AND NOT EXISTS (
       SELECT 1 FROM public.order_items
       WHERE order_id = p_order_id AND stock_deducted
     ) THEN
    RETURN;
  END IF;

  FOR v_net IN
    SELECT
      st.outlet_id,
      st.ingredient_id,
      GREATEST(
        SUM(CASE
          WHEN st.type = 'usage' THEN st.qty
          WHEN st.type = 'return' THEN -st.qty
          ELSE 0
        END),
        0
      ) AS qty
    FROM public.stock_transactions st
    WHERE st.order_id = p_order_id
      AND st.type IN ('usage', 'return')
    GROUP BY st.outlet_id, st.ingredient_id
    HAVING SUM(CASE
      WHEN st.type = 'usage' THEN st.qty
      WHEN st.type = 'return' THEN -st.qty
      ELSE 0
    END) > 0
  LOOP
    SELECT * INTO v_ing
    FROM public.ingredients
    WHERE id = v_net.ingredient_id
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    INSERT INTO public.stock_transactions(
      outlet_id, ingredient_id, type, qty, qty_before, qty_after,
      notes, order_id, created_by
    ) VALUES (
      v_net.outlet_id, v_net.ingredient_id, 'return', v_net.qty,
      v_ing.stock_qty, v_ing.stock_qty + v_net.qty,
      'Batal: Order #' || v_order.order_number,
      p_order_id, auth.uid()
    );
  END LOOP;

  UPDATE public.order_items
  SET stock_deducted = false
  WHERE order_id = p_order_id AND stock_deducted;

  UPDATE public.orders
  SET stock_deducted = false
  WHERE id = p_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.restore_stock_for_order(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.restore_stock_for_order(UUID) TO service_role;

-- ── Void sebagian item ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.void_order_items(
  p_order        UUID,
  p_items        JSONB,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_order       public.orders%ROWTYPE;
  v_item        public.order_items%ROWTYPE;
  v_approver    UUID;
  v_approver_name TEXT;
  v_request     RECORD;
  v_recipe      RECORD;
  v_ing         public.ingredients%ROWTYPE;
  v_qty         INTEGER;
  v_remaining   INTEGER;
  v_amount      NUMERIC;
  v_subtotal    NUMERIC;
  v_discount    NUMERIC;
  v_loyalty     NUMERIC;
  v_tax         NUMERIC;
  v_tax_inclusive BOOLEAN;
  v_service     NUMERIC;
  v_snapshot    JSONB;
  v_voided      JSONB := '[]'::JSONB;
  v_item_count  INTEGER := 0;
  v_total_void  NUMERIC := 0;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Pilih minimal satu item untuk di-void'
      USING ERRCODE = '22023';
  END IF;
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'Pilih atasan yang menyetujui'
      USING ERRCODE = '22023';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Alasan void item wajib diisi'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_order.status = 'paid' THEN
    RAISE EXCEPTION 'Order sudah lunas. Gunakan Refund Sebagian'
      USING ERRCODE = '22023';
  END IF;
  IF v_order.status IN ('void', 'cancelled') THEN
    RAISE EXCEPTION 'Order sudah ditutup' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = p_order) THEN
    RAISE EXCEPTION
      'Order sudah memiliki pembayaran. Selesaikan atau batalkan pembayaran lebih dulu'
      USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR v_order.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Tidak berizin mengubah order ini'
      USING ERRCODE = '42501';
  END IF;

  v_approver := public._find_approver(
    v_order.outlet_id, p_approver_pin, p_approver_id
  );
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;
  SELECT full_name INTO v_approver_name
  FROM public.profiles WHERE id = v_approver;

  -- Gabungkan id yang sama supaya payload duplikat tidak dapat melewati batas
  -- quantity. Cast UUID juga menolak id yang bukan UUID.
  FOR v_request IN
    SELECT
      (x.value->>'order_item_id')::UUID AS item_id,
      SUM((x.value->>'qty')::INTEGER)::INTEGER AS qty
    FROM jsonb_array_elements(p_items) AS x(value)
    GROUP BY (x.value->>'order_item_id')::UUID
    ORDER BY (x.value->>'order_item_id')::UUID
  LOOP
    v_qty := v_request.qty;
    SELECT * INTO v_item
    FROM public.order_items
    WHERE id = v_request.item_id
      AND order_id = p_order
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item tidak ada dalam order ini'
        USING ERRCODE = '22023';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 OR v_qty > v_item.quantity THEN
      RAISE EXCEPTION 'Jumlah void melebihi jumlah item'
        USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_build_object(
      'order_item_id', v_item.id,
      'menu_item_id', v_item.menu_item_id,
      'name', COALESCE(mi.name, 'Menu'),
      'quantity_before', v_item.quantity,
      'quantity_voided', v_qty,
      'unit_price', v_item.unit_price,
      'notes', v_item.notes,
      'options', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'extra_name', oio.extra_name,
          'option_name', oio.option_name,
          'price', oio.price
        ) ORDER BY oio.created_at)
        FROM public.order_item_options oio
        WHERE oio.order_item_id = v_item.id
      ), '[]'::JSONB)
    )
    INTO v_snapshot
    FROM public.menu_items mi
    WHERE mi.id = v_item.menu_item_id;

    IF v_snapshot IS NULL THEN
      v_snapshot := jsonb_build_object(
        'order_item_id', v_item.id,
        'menu_item_id', v_item.menu_item_id,
        'name', 'Menu',
        'quantity_before', v_item.quantity,
        'quantity_voided', v_qty,
        'unit_price', v_item.unit_price,
        'notes', v_item.notes,
        'options', '[]'::JSONB
      );
    END IF;

    v_amount := v_item.unit_price * v_qty;

    -- Kembalikan stok secara proporsional hanya jika item ini memang sudah
    -- pernah memotong stok.
    IF COALESCE(v_item.stock_deducted, false) THEN
      FOR v_recipe IN
        SELECT ingredient_id, qty_per_portion
        FROM public.v_effective_recipe
        WHERE menu_item_id = v_item.menu_item_id
      LOOP
        SELECT * INTO v_ing
        FROM public.ingredients
        WHERE id = v_recipe.ingredient_id
        FOR UPDATE;
        IF NOT FOUND THEN CONTINUE; END IF;

        INSERT INTO public.stock_transactions(
          outlet_id, ingredient_id, type, qty, qty_before, qty_after,
          notes, order_id, created_by
        ) VALUES (
          v_order.outlet_id,
          v_recipe.ingredient_id,
          'return',
          v_recipe.qty_per_portion * v_qty,
          v_ing.stock_qty,
          v_ing.stock_qty + (v_recipe.qty_per_portion * v_qty),
          'Void item: Order #' || v_order.order_number,
          p_order,
          auth.uid()
        );
      END LOOP;
    END IF;

    INSERT INTO public.order_item_voids(
      order_id, shift_id, outlet_id, order_item_id, menu_item_id,
      menu_name, quantity, unit_price, amount, item_snapshot, reason,
      voided_by, approved_by
    ) VALUES (
      p_order, v_order.shift_id, v_order.outlet_id, v_item.id,
      v_item.menu_item_id, COALESCE(v_snapshot->>'name', 'Menu'),
      v_qty, v_item.unit_price, v_amount, v_snapshot, btrim(p_reason),
      auth.uid(), v_approver
    );

    v_remaining := v_item.quantity - v_qty;
    IF v_remaining = 0 THEN
      DELETE FROM public.order_items WHERE id = v_item.id;
    ELSE
      UPDATE public.order_items
      SET quantity = v_remaining,
          subtotal = unit_price * v_remaining
      WHERE id = v_item.id;
    END IF;

    v_item_count := v_item_count + v_qty;
    v_total_void := v_total_void + v_amount;
    v_voided := v_voided || jsonb_build_array(
      v_snapshot || jsonb_build_object('quantity_after', v_remaining)
    );
  END LOOP;

  SELECT COUNT(*), COALESCE(SUM(subtotal), 0)
  INTO v_item_count, v_subtotal
  FROM public.order_items
  WHERE order_id = p_order;

  IF v_item_count = 0 THEN
    -- Semua item habis. Stoknya telah dikembalikan di atas; matikan flag agar
    -- trigger status void tidak melakukan restore kedua.
    UPDATE public.orders SET stock_deducted = false WHERE id = p_order;
    PERFORM set_config('app.order_financial_mutation', 'on', true);
    PERFORM set_config('app.order_status_mutation', 'on', true);
    UPDATE public.orders
    SET subtotal = 0,
        discount_amount = 0,
        loyalty_discount = 0,
        tax_amount = 0,
        service_charge = 0,
        status = 'void',
        void_reason = btrim(p_reason),
        approved_by = v_approver,
        updated_at = now()
    WHERE id = p_order;
  ELSE
    -- Pertahankan diskon selama masih muat pada subtotal baru. Pajak dan biaya
    -- layanan selalu dihitung ulang dari konfigurasi server.
    v_discount := LEAST(COALESCE(v_order.discount_amount, 0), v_subtotal);
    v_loyalty := LEAST(
      COALESCE(v_order.loyalty_discount, 0),
      GREATEST(v_subtotal - v_discount, 0)
    );
    SELECT tax_amount, tax_inclusive, service_charge
    INTO v_tax, v_tax_inclusive, v_service
    FROM public.calculate_server_order_totals(
      v_order.outlet_id, v_order.order_type, v_subtotal,
      v_discount, v_loyalty
    );

    PERFORM set_config('app.order_financial_mutation', 'on', true);
    UPDATE public.orders
    SET subtotal = v_subtotal,
        discount_amount = v_discount,
        loyalty_discount = v_loyalty,
        tax_amount = v_tax,
        tax_inclusive = v_tax_inclusive,
        service_charge = v_service,
        updated_at = now()
    WHERE id = p_order;
    PERFORM public.validate_order_financial_integrity(p_order);
  END IF;

  INSERT INTO public.order_audit_log(
    order_id, outlet_id, actor_id, actor_name, action,
    old_value, new_value, notes
  ) VALUES (
    p_order, v_order.outlet_id, auth.uid(),
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()),
    'item_removed',
    jsonb_build_object(
      'subtotal', v_order.subtotal,
      'total_amount', v_order.total_amount
    ),
    jsonb_build_object(
      'items', v_voided,
      'subtotal', (SELECT subtotal FROM public.orders WHERE id = p_order),
      'total_amount', (SELECT total_amount FROM public.orders WHERE id = p_order),
      'approved_by', v_approver,
      'approver_name', v_approver_name
    ),
    btrim(p_reason)
  );

  RETURN jsonb_build_object(
    'order_id', p_order,
    'items', v_voided,
    'amount', v_total_void,
    'order_status', (SELECT status FROM public.orders WHERE id = p_order),
    'approver', v_approver_name
  );
END;
$$;

REVOKE ALL ON FUNCTION public.void_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  TO authenticated;

-- ── Laporan tutup kasir ─────────────────────────────────────────────────────
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
      SUM(GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0))::INTEGER AS qty,
      SUM(
        GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0) * oi.unit_price
      ) AS amount
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE o.shift_id = p_shift_id
      AND o.status = 'paid'
    GROUP BY COALESCE(mi.name, 'Menu')
    HAVING SUM(GREATEST(oi.quantity - COALESCE(oi.refunded_qty, 0), 0)) > 0
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
    'completed_transactions', (
      SELECT COUNT(*) FROM public.orders o
      WHERE o.shift_id = p_shift_id AND o.status = 'paid'
    ),
    'unpaid_transactions', (
      SELECT COUNT(*) FROM public.orders o
      WHERE o.shift_id = p_shift_id
        AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
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
  'Snapshot laporan tutup kasir: penerimaan bersih, rekonsiliasi laci, jumlah '
  'transaksi, metode pembayaran, dan produk terjual.';

-- Tutup + bentuk laporan dalam satu transaksi. Jika laporan gagal dibentuk,
-- penutupan ikut dibatalkan sehingga aplikasi tidak berada pada keadaan
-- "shift sudah tertutup tetapi laporan tidak tersedia".
CREATE OR REPLACE FUNCTION public.close_shift_with_report(
  p_shift_id UUID,
  p_closing_cash NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
BEGIN
  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR (
      v_shift.outlet_id = public.auth_outlet_id()
      AND v_role IN ('admin', 'manajer')
    )
    OR (
      v_shift.outlet_id = public.auth_outlet_id()
      AND v_role = 'kasir'
      AND v_shift.kasir_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'Tidak berizin menutup shift ini'
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.close_shift(p_shift_id, p_closing_cash, p_notes);
  RETURN public.get_shift_close_report(p_shift_id);
END;
$$;

REVOKE ALL ON FUNCTION public.close_shift_with_report(UUID, NUMERIC, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_shift_with_report(UUID, NUMERIC, TEXT)
  TO authenticated;

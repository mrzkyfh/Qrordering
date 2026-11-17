-- 163_edit_confirmed_online_order.sql
--
-- Kasir dapat mengoreksi seluruh isi pesanan online selama order masih draft
-- atau confirmed (belum masuk proses dapur) dan belum menerima pembayaran.
-- Nomor/order id dipertahankan. Item, total, stok, dan audit berubah atomik.

CREATE OR REPLACE FUNCTION public.replace_online_order_items(
  p_order_id UUID,
  p_items JSONB,
  p_customer_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_promo public.promos%ROWTYPE;
  v_old_items JSONB;
  v_new_items JSONB;
  v_new_subtotal NUMERIC;
  v_discount NUMERIC;
  v_loyalty NUMERIC;
  v_tax NUMERIC;
  v_tax_inclusive BOOLEAN;
  v_service NUMERIC;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang mengedit pesanan online'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND OR NOT (
    COALESCE(public.is_owner(), false)
    OR v_order.outlet_id = public.auth_outlet_id()
  ) THEN
    RAISE EXCEPTION 'Pesanan online tidak ditemukan atau tidak berwenang'
      USING ERRCODE = '42501';
  END IF;

  IF v_order.order_type <> 'self_order' THEN
    RAISE EXCEPTION 'Fitur ini hanya untuk pesanan online'
      USING ERRCODE = '22023';
  END IF;
  IF v_order.status NOT IN ('draft', 'confirmed') THEN
    RAISE EXCEPTION
      'Pesanan online hanya dapat diedit sebelum masuk proses dapur'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.payments WHERE order_id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Pesanan yang sudah menerima pembayaran tidak dapat diedit'
      USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Pesanan harus memiliki minimal satu item'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', oi.id,
        'menu_item_id', oi.menu_item_id,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'subtotal', oi.subtotal,
        'notes', oi.notes
      )
      ORDER BY oi.id
    ),
    '[]'::JSONB
  )
  INTO v_old_items
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id;

  -- Kembalikan pemakaian bersih item lama sebelum menggantinya. Fungsi restore
  -- versi 161 memperhitungkan return parsial sehingga stok tidak kembali ganda.
  PERFORM public.restore_stock_for_order(p_order_id);
  DELETE FROM public.order_items WHERE order_id = p_order_id;

  -- append_order_items memvalidasi menu/extra/harga, menghitung ulang nominal,
  -- memasukkan opsi, dan memotong stok item baru dalam transaksi yang sama.
  v_new_items := public.append_order_items(
    p_order_id,
    p_items,
    0,
    true,
    0
  );

  -- append_order_items juga memotong stok agar aman untuk open bill. Self-order
  -- draft belum semestinya mengurangi stok; netralkan lagi sampai order
  -- dikonfirmasi. Untuk confirmed, pemotongan item baru dipertahankan.
  IF v_order.status = 'draft' THEN
    PERFORM public.restore_stock_for_order(p_order_id);
  END IF;

  SELECT subtotal
    INTO v_new_subtotal
  FROM public.orders
  WHERE id = p_order_id;

  v_discount := COALESCE(v_order.discount_amount, 0);
  v_loyalty := COALESCE(v_order.loyalty_discount, 0);

  -- Promo persentase/tetap mengikuti subtotal baru. Promo jenis paket/BOGO
  -- mempertahankan nilai yang telah divalidasi saat pelanggan membuat order.
  IF v_order.promo_id IS NOT NULL THEN
    SELECT *
      INTO v_promo
    FROM public.promos
    WHERE id = v_order.promo_id
      AND outlet_id = v_order.outlet_id;

    IF NOT FOUND
       OR NOT v_promo.is_active
       OR (v_promo.start_date IS NOT NULL
           AND v_promo.start_date > public.jkt_today())
       OR (v_promo.end_date IS NOT NULL
           AND v_promo.end_date < public.jkt_today())
       OR v_new_subtotal < v_promo.min_order THEN
      RAISE EXCEPTION
        'Perubahan item tidak memenuhi ketentuan promo pada pesanan'
        USING ERRCODE = '22023';
    END IF;

    v_discount := CASE v_promo.type
      WHEN 'percentage' THEN LEAST(
        round(v_new_subtotal * v_promo.value / 100, 0),
        COALESCE(
          v_promo.max_discount,
          round(v_new_subtotal * v_promo.value / 100, 0)
        )
      )
      WHEN 'fixed' THEN LEAST(v_promo.value, v_new_subtotal)
      ELSE LEAST(v_discount, v_new_subtotal)
    END;
  END IF;

  IF v_discount + v_loyalty > v_new_subtotal THEN
    RAISE EXCEPTION
      'Nilai item baru lebih kecil dari diskon/poin pesanan'
      USING ERRCODE = '22023';
  END IF;

  SELECT tax_amount, tax_inclusive, service_charge
    INTO v_tax, v_tax_inclusive, v_service
  FROM public.calculate_server_order_totals(
    v_order.outlet_id,
    v_order.order_type,
    v_new_subtotal,
    v_discount,
    v_loyalty
  );

  PERFORM set_config('app.order_financial_mutation', 'on', true);
  UPDATE public.orders
  SET discount_amount = v_discount,
      tax_amount = v_tax,
      tax_inclusive = v_tax_inclusive,
      service_charge = v_service,
      customer_name = NULLIF(btrim(p_customer_name), ''),
      stock_deducted = (v_order.status = 'confirmed'),
      kitchen_printed = false,
      updated_at = now()
  WHERE id = p_order_id;

  PERFORM public.validate_order_financial_integrity(p_order_id);

  INSERT INTO public.order_audit_log(
    order_id,
    outlet_id,
    actor_id,
    actor_name,
    action,
    old_value,
    new_value,
    notes
  ) VALUES (
    p_order_id,
    v_order.outlet_id,
    auth.uid(),
    (
      SELECT full_name
      FROM public.profiles
      WHERE id = auth.uid()
    ),
    'items_edited',
    jsonb_build_object(
      'items', v_old_items,
      'subtotal', v_order.subtotal,
      'total_amount', v_order.total_amount
    ),
    jsonb_build_object(
      'items', v_new_items,
      'subtotal', (
        SELECT subtotal FROM public.orders WHERE id = p_order_id
      ),
      'total_amount', (
        SELECT total_amount FROM public.orders WHERE id = p_order_id
      )
    ),
    'Pesanan online diedit sebelum proses dapur'
  );

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'order_number', v_order.order_number,
    'items', v_new_items,
    'subtotal', (
      SELECT subtotal FROM public.orders WHERE id = p_order_id
    ),
    'total_amount', (
      SELECT total_amount FROM public.orders WHERE id = p_order_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.replace_online_order_items(UUID, JSONB, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_online_order_items(UUID, JSONB, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.replace_online_order_items(UUID, JSONB, TEXT) IS
  'Mengganti item self-order draft/confirmed yang belum dibayar secara atomik, '
  'termasuk perhitungan total, stok, dan audit.';

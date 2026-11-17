-- 142_remaining_integrity_hardening.sql
-- Menutup celah yang ditemukan setelah hardening transaksi 141:
--   1. RPC hapus menu/bahan wajib owner/admin dan scoped outlet.
--   2. Refund per-item dikunci agar dua request bersamaan tidak over-refund.
--   3. Loyalty member/history tidak lagi bisa dihapus atau diubah langsung.
--   4. Penyesuaian poin dilakukan atomik di database.
--   5. Mutasi stok langsung dibatasi ke RPC owner/admin.
--   6. Signature RPC approval lama dicabut.

-- ── 1. Smart delete master data: jangan tembus RLS lintas outlet ───────────
CREATE OR REPLACE FUNCTION public.delete_menu_item_smart(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_outlet UUID;
  v_has_orders BOOLEAN;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat menghapus menu'
      USING ERRCODE = '42501';
  END IF;

  SELECT outlet_id INTO v_outlet
  FROM public.menu_items
  WHERE id = p_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_outlet IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Menu bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.order_items WHERE menu_item_id = p_id
  ) INTO v_has_orders;

  IF v_has_orders THEN
    UPDATE public.menu_items
    SET is_active = false, is_available = false
    WHERE id = p_id;
    RETURN jsonb_build_object(
      'status', 'archived',
      'reason', 'Menu sudah pernah dipesan — diarsipkan agar laporan tetap akurat'
    );
  END IF;

  DELETE FROM public.menu_items WHERE id = p_id;
  RETURN jsonb_build_object('status', 'deleted');
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_ingredient_smart(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_outlet UUID;
  v_has_tx BOOLEAN;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat menghapus bahan'
      USING ERRCODE = '42501';
  END IF;

  SELECT outlet_id INTO v_outlet
  FROM public.ingredients
  WHERE id = p_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_outlet IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Bahan bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.stock_transactions WHERE ingredient_id = p_id
  ) INTO v_has_tx;

  IF v_has_tx THEN
    UPDATE public.ingredients SET is_active = false WHERE id = p_id;
    RETURN jsonb_build_object(
      'status', 'archived',
      'reason', 'Bahan sudah memiliki histori stok — diarsipkan untuk audit'
    );
  END IF;

  DELETE FROM public.ingredients WHERE id = p_id;
  RETURN jsonb_build_object('status', 'deleted');
END;
$$;

REVOKE ALL ON FUNCTION public.delete_menu_item_smart(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_menu_item_smart(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.delete_ingredient_smart(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_ingredient_smart(UUID) TO authenticated;

-- ── 2. Refund sebagian: lock order + item sebelum menghitung qty ───────────
CREATE OR REPLACE FUNCTION public.refund_order_items(
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
  v_outlet   UUID;
  v_status   public.order_status;
  v_approver UUID;
  v_refund   UUID;
  v_method   public.payment_method;
  v_total    NUMERIC := 0;
  v_it       JSONB;
  v_item     public.order_items%ROWTYPE;
  v_qty      INTEGER;
  v_amount   NUMERIC;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Item refund wajib diisi' USING ERRCODE = '22023';
  END IF;

  -- Lock header lebih dulu. Semua refund order yang sama antre di sini.
  SELECT outlet_id, status INTO v_outlet, v_status
  FROM public.orders
  WHERE id = p_order
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status <> 'paid' THEN
    RAISE EXCEPTION 'Hanya order lunas yang bisa direfund sebagian';
  END IF;
  IF NOT (COALESCE(public.is_owner(), false)
          OR v_outlet = public.auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini';
  END IF;

  v_approver := public._find_approver(v_outlet, p_approver_pin, p_approver_id);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  v_method := COALESCE(
    (SELECT p.method FROM public.payments p
     WHERE p.order_id = p_order
     ORDER BY p.amount DESC LIMIT 1),
    'cash');

  INSERT INTO public.refunds(
    order_id, outlet_id, amount, method, reason, refunded_by, approved_by
  ) VALUES (
    p_order, v_outlet, 0, v_method, p_reason, auth.uid(), v_approver
  ) RETURNING id INTO v_refund;

  FOR v_it IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_it->>'qty')::INTEGER;
    SELECT * INTO v_item
    FROM public.order_items
    WHERE id = (v_it->>'order_item_id')::UUID
      AND order_id = p_order
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ada dalam order ini'; END IF;
    IF v_qty IS NULL OR v_qty <= 0
       OR COALESCE(v_item.refunded_qty, 0) + v_qty > v_item.quantity THEN
      RAISE EXCEPTION 'Qty refund melebihi qty terjual';
    END IF;

    v_amount := v_item.unit_price * v_qty;
    UPDATE public.order_items
    SET refunded_qty = COALESCE(refunded_qty, 0) + v_qty
    WHERE id = v_item.id;
    INSERT INTO public.refund_items(refund_id, order_item_id, qty, amount)
    VALUES (v_refund, v_item.id, v_qty, v_amount);
    v_total := v_total + v_amount;
  END LOOP;

  IF v_total <= 0 THEN RAISE EXCEPTION 'Tidak ada item untuk direfund'; END IF;
  UPDATE public.refunds SET amount = v_total WHERE id = v_refund;

  RETURN jsonb_build_object(
    'refund_id', v_refund,
    'amount', v_total,
    'approver', (SELECT full_name FROM public.profiles WHERE id = v_approver)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_items(UUID, JSONB, TEXT, TEXT, UUID)
  TO authenticated;

-- ── 3. Loyalty: histori immutable, delete menjadi archive ─────────────────
DROP POLICY IF EXISTS "loyalty_members_crud" ON public.loyalty_members;
DROP POLICY IF EXISTS "loyalty_members_select" ON public.loyalty_members;
DROP POLICY IF EXISTS "loyalty_members_insert" ON public.loyalty_members;
DROP POLICY IF EXISTS "loyalty_members_update" ON public.loyalty_members;
DROP POLICY IF EXISTS "loyalty_members_delete" ON public.loyalty_members;

CREATE POLICY "loyalty_members_select" ON public.loyalty_members
  FOR SELECT TO authenticated
  USING (
    COALESCE(public.is_owner(), false)
    OR (public.auth_role() IN ('admin') AND outlet_id = public.auth_outlet_id())
  );
CREATE POLICY "loyalty_members_insert" ON public.loyalty_members
  FOR INSERT TO authenticated
  WITH CHECK (
    COALESCE(public.is_owner(), false)
    OR (public.auth_role() IN ('admin') AND outlet_id = public.auth_outlet_id())
  );
CREATE POLICY "loyalty_members_update" ON public.loyalty_members
  FOR UPDATE TO authenticated
  USING (
    COALESCE(public.is_owner(), false)
    OR (public.auth_role() IN ('admin') AND outlet_id = public.auth_outlet_id())
  )
  WITH CHECK (
    COALESCE(public.is_owner(), false)
    OR (public.auth_role() IN ('admin') AND outlet_id = public.auth_outlet_id())
  );

DROP POLICY IF EXISTS "loyalty_txn_crud" ON public.loyalty_transactions;
DROP POLICY IF EXISTS "loyalty_txn_select" ON public.loyalty_transactions;
DROP POLICY IF EXISTS "loyalty_txn_insert" ON public.loyalty_transactions;
CREATE POLICY "loyalty_txn_select" ON public.loyalty_transactions
  FOR SELECT TO authenticated
  USING (
    COALESCE(public.is_owner(), false)
    OR (public.auth_role() IN ('admin') AND outlet_id = public.auth_outlet_id())
  );

CREATE OR REPLACE FUNCTION public.archive_loyalty_member(p_member_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_outlet UUID;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat mengarsipkan member'
      USING ERRCODE = '42501';
  END IF;
  SELECT outlet_id INTO v_outlet
  FROM public.loyalty_members
  WHERE id = p_member_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member tidak ditemukan'; END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_outlet IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Member bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;
  UPDATE public.loyalty_members SET is_active = false WHERE id = p_member_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.adjust_loyalty_points(
  p_member_id UUID,
  p_points INTEGER,
  p_description TEXT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_member public.loyalty_members%ROWTYPE;
  v_new_points INTEGER;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat menyesuaikan poin'
      USING ERRCODE = '42501';
  END IF;
  IF p_points IS NULL OR p_points = 0 THEN
    RAISE EXCEPTION 'Perubahan poin tidak boleh nol' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(btrim(p_description), '') IS NULL THEN
    RAISE EXCEPTION 'Alasan penyesuaian poin wajib diisi' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_member
  FROM public.loyalty_members
  WHERE id = p_member_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_member.is_active THEN
    RAISE EXCEPTION 'Member tidak aktif atau tidak ditemukan';
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_member.outlet_id IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Member bukan milik outlet Anda' USING ERRCODE = '42501';
  END IF;

  v_new_points := v_member.points + p_points;
  IF v_new_points < 0 THEN
    RAISE EXCEPTION 'Poin tidak mencukupi untuk dikurangi';
  END IF;

  INSERT INTO public.loyalty_transactions(
    member_id, outlet_id, type, points, description
  ) VALUES (
    v_member.id, v_member.outlet_id, 'adjustment', p_points,
    btrim(p_description)
  );
  UPDATE public.loyalty_members
  SET points = v_new_points
  WHERE id = v_member.id;
  RETURN v_new_points;
END;
$$;

REVOKE ALL ON FUNCTION public.archive_loyalty_member(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archive_loyalty_member(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.adjust_loyalty_points(UUID, INTEGER, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_loyalty_points(UUID, INTEGER, TEXT)
  TO authenticated;

-- ── 4. Stok: insert ledger hanya melalui RPC berotorisasi ──────────────────
CREATE OR REPLACE FUNCTION public.adjust_stock(
  p_outlet_id     UUID,
  p_ingredient_id UUID,
  p_type          TEXT,
  p_qty           NUMERIC,
  p_cost_per_unit NUMERIC DEFAULT NULL,
  p_notes         TEXT DEFAULT NULL,
  p_created_by    UUID DEFAULT NULL,
  p_supplier_id   UUID DEFAULT NULL,
  p_reason        TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_qty_before NUMERIC;
  v_qty_after NUMERIC;
  v_outlet UUID;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Hanya owner/admin yang dapat mengubah stok'
      USING ERRCODE = '42501';
  END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'Jumlah stok harus lebih besar dari nol' USING ERRCODE = '22023';
  END IF;
  IF p_type NOT IN ('purchase', 'return', 'adjustment', 'usage', 'waste') THEN
    RAISE EXCEPTION 'Jenis transaksi stok tidak valid' USING ERRCODE = '22023';
  END IF;
  IF p_cost_per_unit IS NOT NULL AND p_cost_per_unit < 0 THEN
    RAISE EXCEPTION 'Biaya satuan tidak valid' USING ERRCODE = '22023';
  END IF;

  SELECT stock_qty, outlet_id INTO v_qty_before, v_outlet
  FROM public.ingredients
  WHERE id = p_ingredient_id
  FOR UPDATE;
  IF NOT FOUND OR v_outlet IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Bahan tidak ditemukan di outlet tersebut'
      USING ERRCODE = '42501';
  END IF;
  IF p_supplier_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.suppliers
    WHERE id = p_supplier_id AND outlet_id = p_outlet_id AND is_active
  ) THEN
    RAISE EXCEPTION 'Supplier tidak valid untuk outlet tersebut'
      USING ERRCODE = '22023';
  END IF;

  v_qty_after := CASE
    WHEN p_type IN ('purchase', 'return', 'adjustment')
      THEN v_qty_before + p_qty
    ELSE v_qty_before - p_qty
  END;

  INSERT INTO public.stock_transactions(
    outlet_id, ingredient_id, type, qty_before, qty, qty_after,
    cost_per_unit, notes, created_by, supplier_id, reason
  ) VALUES (
    p_outlet_id, p_ingredient_id, p_type::public.stock_transaction_type,
    v_qty_before, p_qty, v_qty_after, p_cost_per_unit, p_notes,
    auth.uid(), p_supplier_id, p_reason
  );
END;
$$;

REVOKE INSERT ON public.stock_transactions FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.adjust_stock(
  UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, UUID, UUID, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_stock(
  UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, UUID, UUID, TEXT
) TO authenticated;

-- ── 5. Cabut overload approval lama yang tidak lagi dipakai ────────────────
-- Signature lama tidak selalu ada pada database yang sudah pernah menjalankan
-- migration pembersihan overload. Gunakan pengecekan katalog agar migration
-- tetap bisa dijalankan utuh maupun ditempel manual di SQL Editor.
DO $$
BEGIN
  IF to_regprocedure('public.void_order_with_approval(uuid,text,text)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.void_order_with_approval(UUID, TEXT, TEXT) '
      || 'FROM PUBLIC, anon, authenticated';
  END IF;
  IF to_regprocedure('public.refund_order_with_approval(uuid,text,text)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.refund_order_with_approval(UUID, TEXT, TEXT) '
      || 'FROM PUBLIC, anon, authenticated';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.refund_order_items(UUID, JSONB, TEXT, TEXT, UUID) IS
  'Refund per-item atomik: order dan item dikunci agar concurrent request tidak over-refund (142).';
COMMENT ON FUNCTION public.adjust_loyalty_points(UUID, INTEGER, TEXT) IS
  'Penyesuaian poin atomik dengan lock member dan histori immutable (142).';

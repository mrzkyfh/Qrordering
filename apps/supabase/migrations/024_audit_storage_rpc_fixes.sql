-- ============================================================
-- 024_audit_storage_rpc_fixes.sql
-- Fix dari API testing advanced 2026-05-27
-- BUG-AUDIT-001, BUG-AUDIT-002, BUG-RPC-001, BUG-RPC-002
-- ============================================================

-- ── BUG-AUDIT-001 ────────────────────────────────────────────
-- order_audit_log_select: SELECT id FROM outlets WHERE TRUE
-- mengembalikan SEMUA outlet → setiap user bisa baca semua audit log.
DROP POLICY IF EXISTS "order_audit_log_select" ON order_audit_log;
CREATE POLICY "order_audit_log_select" ON order_audit_log
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

-- ── BUG-AUDIT-002 ────────────────────────────────────────────
-- order_audit_log_insert: WITH CHECK (true) → siapapun bisa inject
-- audit log palsu dengan actor_id orang lain.
DROP POLICY IF EXISTS "order_audit_log_insert" ON order_audit_log;
CREATE POLICY "order_audit_log_insert" ON order_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    (is_owner() OR outlet_id = auth_outlet_id())
    AND actor_id = auth.uid()
  );

-- ── BUG-RPC-001 ──────────────────────────────────────────────
-- adjust_stock tidak memvalidasi p_outlet_id terhadap ingredient.outlet_id
-- → bisa buat stock_transaction dengan outlet mismatch.
-- Sekalian tambah guard BUG-RPC-002: double-close shift.
CREATE OR REPLACE FUNCTION adjust_stock(
  p_outlet_id UUID,
  p_ingredient_id UUID,
  p_type text,
  p_qty numeric,
  p_cost_per_unit numeric DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_created_by UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_qty_before numeric;
  v_qty_after numeric;
  v_ingredient_outlet UUID;
BEGIN
  SELECT stock_qty, outlet_id
  INTO v_qty_before, v_ingredient_outlet
  FROM ingredients
  WHERE id = p_ingredient_id
  FOR UPDATE;

  IF v_ingredient_outlet IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'ingredient does not belong to the specified outlet';
  END IF;

  IF p_type IN ('purchase', 'return', 'adjustment') THEN
    v_qty_after := v_qty_before + p_qty;
  ELSE
    v_qty_after := GREATEST(v_qty_before - p_qty, 0);
  END IF;

  INSERT INTO stock_transactions (
    outlet_id, ingredient_id, type,
    qty_before, qty, qty_after,
    cost_per_unit, notes, created_by
  ) VALUES (
    p_outlet_id, p_ingredient_id, p_type::stock_transaction_type,
    v_qty_before, p_qty, v_qty_after,
    p_cost_per_unit, p_notes, p_created_by
  );
END;
$$;

-- ── BUG-RPC-002 ──────────────────────────────────────────────
-- close_shift tidak mendeteksi shift yang sudah ditutup.
CREATE OR REPLACE FUNCTION close_shift(
  p_shift_id UUID,
  p_closing_cash numeric,
  p_notes text DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_cash_total numeric := 0;
  v_opening_cash numeric := 0;
  v_expected_cash numeric := 0;
  v_cash_difference numeric := 0;
BEGIN
  -- Guard: tolak jika shift sudah ditutup
  IF EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND end_time IS NOT NULL) THEN
    RAISE EXCEPTION 'shift already closed';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM payments p
  JOIN orders o ON o.id = p.order_id
  WHERE o.shift_id = p_shift_id
    AND o.status = 'paid'
    AND p.method = 'cash';

  SELECT opening_cash INTO v_opening_cash
  FROM shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  v_expected_cash := v_opening_cash + v_cash_total;
  v_cash_difference := p_closing_cash - v_expected_cash;

  UPDATE shifts
  SET end_time = NOW(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

-- ── BUG-STOR-001 ─────────────────────────────────────────────
-- Storage menu-images tidak punya path isolation.
-- Kasir outlet A bisa overwrite gambar outlet B.
-- Fix: validasi folder pertama path harus = outlet_id user.
-- Konvensi path: menu-images/{outlet_id}/{filename}
DROP POLICY IF EXISTS "menu_images_auth_insert" ON storage.objects;
CREATE POLICY "menu_images_auth_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::text FROM profiles WHERE id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS "menu_images_auth_update" ON storage.objects;
CREATE POLICY "menu_images_auth_update" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::text FROM profiles WHERE id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS "menu_images_auth_delete" ON storage.objects;
CREATE POLICY "menu_images_auth_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::text FROM profiles WHERE id = auth.uid()
      )
    )
  );

-- 100_stock_opname.sql
-- FITUR ROADMAP-1 — Stok Opname (audit stok fisik).
--
-- Alur: buat opname (snapshot system_qty semua bahan aktif) → isi physical_qty
-- → finalize → tiap selisih dibuat stock_transactions 'adjustment' → stok sistem
-- disamakan ke fisik. Sumber kebenaran stok tetap trigger apply_stock_transaction.
--
-- Catatan penting: 'adjustment' sebelumnya HANYA menambah (stock + qty). Opname
-- butuh 2 arah (fisik bisa < sistem). Trigger branch 'adjustment' diubah memakai
-- delta (qty_after - qty_before); magnitudo tetap = qty, kasus 'tambah' tak
-- berubah (delta = +qty), tapi kini bisa mengurangi bila qty_after < qty_before.

-- ── Trigger: 'adjustment' jadi dua-arah via delta qty_after-qty_before ───────
CREATE OR REPLACE FUNCTION apply_stock_transaction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type IN ('purchase', 'return') THEN
    UPDATE ingredients
    SET stock_qty = stock_qty + NEW.qty, updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type = 'adjustment' THEN
    -- Dua-arah: koreksi bisa naik/turun. Magnitudo = qty (CHECK qty>0 aman).
    UPDATE ingredients
    SET stock_qty = stock_qty + (NEW.qty_after - NEW.qty_before), updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type IN ('usage', 'waste') THEN
    UPDATE ingredients
    SET stock_qty = stock_qty - NEW.qty, updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  END IF;
  RETURN NEW;
END;
$$;

-- ── Tabel header opname ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_opnames (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id    UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  note         TEXT,
  status       TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'final')),
  created_by   UUID REFERENCES profiles(id) ON DELETE SET NULL,
  finalized_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  finalized_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_stock_opnames_outlet ON stock_opnames(outlet_id, created_at DESC);

-- ── Tabel item opname ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_opname_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opname_id     UUID NOT NULL REFERENCES stock_opnames(id) ON DELETE CASCADE,
  ingredient_id UUID NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
  system_qty    NUMERIC(10,3) NOT NULL,             -- snapshot saat opname dibuat
  physical_qty  NUMERIC(10,3),                      -- diisi saat hitung fisik
  diff          NUMERIC(10,3) GENERATED ALWAYS AS (physical_qty - system_qty) STORED,
  note          TEXT,
  UNIQUE (opname_id, ingredient_id)
);
CREATE INDEX IF NOT EXISTS idx_stock_opname_items_opname ON stock_opname_items(opname_id);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE stock_opnames      ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_opname_items ENABLE ROW LEVEL SECURITY;

-- Baca: owner atau staf outlet sendiri.
DROP POLICY IF EXISTS "stock_opnames_select" ON stock_opnames;
CREATE POLICY "stock_opnames_select" ON stock_opnames
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

-- Tulis: owner atau admin+ (rank >= 3) outlet sendiri.
DROP POLICY IF EXISTS "stock_opnames_write" ON stock_opnames;
CREATE POLICY "stock_opnames_write" ON stock_opnames
  FOR ALL TO authenticated
  USING (is_owner() OR (auth_rank() >= 3 AND outlet_id = auth_outlet_id()))
  WITH CHECK (is_owner() OR (auth_rank() >= 3 AND outlet_id = auth_outlet_id()));

DROP POLICY IF EXISTS "stock_opname_items_select" ON stock_opname_items;
CREATE POLICY "stock_opname_items_select" ON stock_opname_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM stock_opnames o WHERE o.id = opname_id
      AND (is_owner() OR o.outlet_id = auth_outlet_id())));

DROP POLICY IF EXISTS "stock_opname_items_write" ON stock_opname_items;
CREATE POLICY "stock_opname_items_write" ON stock_opname_items
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM stock_opnames o WHERE o.id = opname_id
      AND (is_owner() OR (auth_rank() >= 3 AND o.outlet_id = auth_outlet_id()))))
  WITH CHECK (EXISTS (
    SELECT 1 FROM stock_opnames o WHERE o.id = opname_id
      AND (is_owner() OR (auth_rank() >= 3 AND o.outlet_id = auth_outlet_id()))));

GRANT SELECT, INSERT, UPDATE, DELETE ON stock_opnames      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON stock_opname_items TO authenticated;

-- ── RPC: buat opname + snapshot semua bahan aktif ───────────────────────────
CREATE OR REPLACE FUNCTION create_stock_opname(
  p_outlet_id UUID,
  p_note      TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SET search_path = public AS $$  -- SECURITY INVOKER: RLS menegakkan hak tulis
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO stock_opnames (outlet_id, note, created_by)
  VALUES (p_outlet_id, p_note, auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO stock_opname_items (opname_id, ingredient_id, system_qty)
  SELECT v_id, i.id, i.stock_qty
  FROM ingredients i
  WHERE i.outlet_id = p_outlet_id AND i.is_active = TRUE;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION create_stock_opname(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_stock_opname(UUID, TEXT) TO authenticated;

-- ── RPC: finalize — terapkan selisih sebagai 'adjustment' ───────────────────
CREATE OR REPLACE FUNCTION finalize_stock_opname(p_opname_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_op  RECORD;
  v_it  RECORD;
  v_cur NUMERIC;
BEGIN
  SELECT * INTO v_op FROM stock_opnames WHERE id = p_opname_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opname not found';
  END IF;
  IF v_op.status = 'final' THEN
    RAISE EXCEPTION 'opname already finalized';
  END IF;
  -- Otorisasi: owner atau admin+ (rank>=3) pada outlet opname.
  IF NOT (is_owner() OR (auth_rank() >= 3 AND auth_outlet_id() = v_op.outlet_id)) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  FOR v_it IN
    SELECT * FROM stock_opname_items
    WHERE opname_id = p_opname_id AND physical_qty IS NOT NULL
  LOOP
    SELECT stock_qty INTO v_cur FROM ingredients WHERE id = v_it.ingredient_id FOR UPDATE;
    CONTINUE WHEN v_cur IS NULL OR v_it.physical_qty = v_cur;

    -- qty_before = stok AKTUAL saat finalize (bukan snapshot) → koreksi tepat ke fisik.
    INSERT INTO stock_transactions
      (outlet_id, ingredient_id, type, qty_before, qty, qty_after, notes, created_by)
    VALUES
      (v_op.outlet_id, v_it.ingredient_id, 'adjustment',
       v_cur, abs(v_it.physical_qty - v_cur), v_it.physical_qty,
       'Opname #' || left(p_opname_id::text, 8), v_op.created_by);
  END LOOP;

  UPDATE stock_opnames
  SET status = 'final', finalized_at = now(), finalized_by = auth.uid()
  WHERE id = p_opname_id;
END;
$$;

REVOKE ALL ON FUNCTION finalize_stock_opname(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finalize_stock_opname(UUID) TO authenticated;

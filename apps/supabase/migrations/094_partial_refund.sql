-- 094_partial_refund.sql
-- FITUR NEW-2 (Fase 1) — Refund sebagian / per-item.
-- Semantik disetujui: order tetap 'paid'; stok TIDAK dikembalikan; wajib PIN
-- approver (manajer/owner/admin); tak boleh refund melebihi qty terjual.
--
-- Fase 1 = data + aksi + audit. Laporan penjualan BELUM dikurangi refund
-- (menyusul di Fase 2 — perbarui view net satu per satu dengan verifikasi).

-- ── Kolom pembatas anti over-refund ─────────────────────────────────────────
ALTER TABLE order_items
  ADD COLUMN IF NOT EXISTS refunded_qty INTEGER NOT NULL DEFAULT 0;

-- ── Jejak refund (audit + sumber pengurang laporan nanti) ───────────────────
CREATE TABLE IF NOT EXISTS refunds (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  outlet_id   UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  reason      TEXT,
  refunded_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  approved_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS refund_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_id     UUID NOT NULL REFERENCES refunds(id) ON DELETE CASCADE,
  order_item_id UUID NOT NULL REFERENCES order_items(id) ON DELETE CASCADE,
  qty           INTEGER NOT NULL CHECK (qty > 0),
  amount        NUMERIC(12,2) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_refunds_order ON refunds(order_id);
CREATE INDEX IF NOT EXISTS idx_refund_items_refund ON refund_items(refund_id);

-- ── RLS: tenant-scoped read; tulis hanya via RPC (SECURITY DEFINER) ─────────
ALTER TABLE refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE refund_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "refunds_select" ON refunds;
CREATE POLICY "refunds_select" ON refunds
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

DROP POLICY IF EXISTS "refund_items_select" ON refund_items;
CREATE POLICY "refund_items_select" ON refund_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM refunds r
    WHERE r.id = refund_items.refund_id
      AND (is_owner() OR r.outlet_id = auth_outlet_id())
  ));

GRANT SELECT ON refunds, refund_items TO authenticated;

-- ── RPC: refund sebagian dengan persetujuan PIN ─────────────────────────────
CREATE OR REPLACE FUNCTION refund_order_items(
  p_order        UUID,
  p_items        JSONB,          -- [{ "order_item_id": "...", "qty": 2 }, ...]
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
  v_status   order_status;
  v_approver UUID;
  v_refund   UUID;
  v_total    NUMERIC := 0;
  v_it       JSONB;
  v_item     order_items%ROWTYPE;
  v_qty      INTEGER;
  v_amount   NUMERIC;
BEGIN
  SELECT outlet_id, status INTO v_outlet, v_status FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;
  IF v_status <> 'paid' THEN
    RAISE EXCEPTION 'Hanya order lunas yang bisa direfund sebagian';
  END IF;
  IF NOT (is_owner() OR v_outlet = auth_outlet_id()) THEN
    RAISE EXCEPTION 'Tidak berizin refund order ini';
  END IF;

  -- Otorisasi PIN atasan (fungsi ini juga menegakkan lockout 5x/5menit).
  v_approver := _find_approver(v_outlet, p_approver_pin, p_approver_id);
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  INSERT INTO refunds (order_id, outlet_id, amount, reason, refunded_by, approved_by)
  VALUES (p_order, v_outlet, 0, p_reason, auth.uid(), v_approver)
  RETURNING id INTO v_refund;

  FOR v_it IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_it->>'qty')::INTEGER;
    SELECT * INTO v_item FROM order_items
    WHERE id = (v_it->>'order_item_id')::UUID AND order_id = p_order;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ada dalam order ini'; END IF;
    IF v_qty <= 0 OR v_item.refunded_qty + v_qty > v_item.quantity THEN
      RAISE EXCEPTION 'Qty refund melebihi qty terjual';
    END IF;

    v_amount := v_item.unit_price * v_qty;
    UPDATE order_items SET refunded_qty = refunded_qty + v_qty WHERE id = v_item.id;
    INSERT INTO refund_items (refund_id, order_item_id, qty, amount)
    VALUES (v_refund, v_item.id, v_qty, v_amount);
    v_total := v_total + v_amount;
  END LOOP;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Tidak ada item untuk direfund';
  END IF;

  UPDATE refunds SET amount = v_total WHERE id = v_refund;

  RETURN jsonb_build_object(
    'refund_id', v_refund,
    'amount', v_total,
    'approver', (SELECT full_name FROM profiles WHERE id = v_approver)
  );
END;
$$;

REVOKE ALL ON FUNCTION refund_order_items(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION refund_order_items(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

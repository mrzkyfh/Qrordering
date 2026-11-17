-- ============================================================
-- 014_loyalty.sql
-- Tabel program loyalty/member pelanggan
-- FR-LOYALTY-01/02/03 | BRD BR-20/21
-- ============================================================

-- ── Tabel member pelanggan ───────────────────────────────────
CREATE TABLE IF NOT EXISTS loyalty_members (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id   UUID        NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  phone       TEXT        NOT NULL,
  name        TEXT,
  points      INTEGER     NOT NULL DEFAULT 0,
  tier        TEXT        NOT NULL DEFAULT 'bronze' CHECK (tier IN ('bronze', 'silver', 'gold', 'platinum')),
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (outlet_id, phone)
);

-- ── Tabel riwayat transaksi poin ─────────────────────────────
CREATE TABLE IF NOT EXISTS loyalty_transactions (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id     UUID        NOT NULL REFERENCES loyalty_members(id) ON DELETE CASCADE,
  outlet_id     UUID        NOT NULL,
  order_id      UUID        REFERENCES orders(id) ON DELETE SET NULL,
  type          TEXT        NOT NULL CHECK (type IN ('earn', 'redeem', 'adjustment', 'expire')),
  points        INTEGER     NOT NULL,  -- positif untuk earn, negatif untuk redeem/expire
  description   TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index
CREATE INDEX IF NOT EXISTS idx_loyalty_members_outlet_phone ON loyalty_members(outlet_id, phone);
CREATE INDEX IF NOT EXISTS idx_loyalty_txn_member           ON loyalty_transactions(member_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loyalty_txn_outlet           ON loyalty_transactions(outlet_id, created_at DESC);

-- Auto-update updated_at pada loyalty_members
CREATE OR REPLACE FUNCTION update_loyalty_member_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loyalty_member_updated
  BEFORE UPDATE ON loyalty_members
  FOR EACH ROW EXECUTE FUNCTION update_loyalty_member_timestamp();

-- RLS
ALTER TABLE loyalty_members     ENABLE ROW LEVEL SECURITY;
ALTER TABLE loyalty_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "loyalty_members_crud" ON loyalty_members
  FOR ALL TO authenticated
  USING (
    outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  )
  WITH CHECK (
    outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  );

CREATE POLICY "loyalty_txn_crud" ON loyalty_transactions
  FOR ALL TO authenticated
  USING (
    outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  )
  WITH CHECK (
    outlet_id IN (SELECT outlet_id FROM profiles WHERE id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  );

-- View ringkasan member
CREATE OR REPLACE VIEW v_loyalty_summary AS
SELECT
  lm.outlet_id,
  lm.tier,
  COUNT(*)::integer                                  AS member_count,
  SUM(lm.points)::integer                            AS total_points_outstanding,
  COUNT(CASE WHEN lm.is_active THEN 1 END)::integer  AS active_members
FROM loyalty_members lm
GROUP BY lm.outlet_id, lm.tier;

GRANT SELECT ON v_loyalty_summary TO authenticated;

COMMENT ON TABLE loyalty_members     IS 'Data member pelanggan per outlet (identifikasi via nomor HP)';
COMMENT ON TABLE loyalty_transactions IS 'Riwayat earn/redeem poin per member';

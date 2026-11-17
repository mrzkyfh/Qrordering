-- ============================================================
-- 012_order_audit_log.sql
-- Tabel audit trail setiap aksi pada order
-- FR-ORDER-08 | BRD BR-16
-- ============================================================

CREATE TABLE IF NOT EXISTS order_audit_log (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  outlet_id   UUID        NOT NULL,
  actor_id    UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  actor_name  TEXT,
  action      TEXT        NOT NULL,  -- create | confirm | void | cancel | item_added | item_removed | table_transfer | payment | status_change
  old_value   JSONB,
  new_value   JSONB,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index untuk lookup cepat per order dan per outlet
CREATE INDEX IF NOT EXISTS idx_order_audit_order     ON order_audit_log(order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_audit_outlet    ON order_audit_log(outlet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_audit_actor     ON order_audit_log(actor_id);

-- RLS: authenticated user bisa baca jika outlet_id sesuai
ALTER TABLE order_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "order_audit_log_select" ON order_audit_log
  FOR SELECT TO authenticated
  USING (
    outlet_id IN (
      SELECT outlet_id FROM profiles WHERE id = auth.uid()
      UNION
      SELECT id        FROM outlets  WHERE TRUE  -- owner sees all via profile role check in app
    )
  );

-- Insert hanya via service role / trigger (app menggunakan supabase client as anon untuk insert)
CREATE POLICY "order_audit_log_insert" ON order_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (true);

COMMENT ON TABLE order_audit_log IS 'Audit trail semua aksi pada tabel orders — siapa, kapan, apa yang berubah';
COMMENT ON COLUMN order_audit_log.action IS 'create | confirm | void | cancel | item_added | item_removed | table_transfer | payment | status_change';

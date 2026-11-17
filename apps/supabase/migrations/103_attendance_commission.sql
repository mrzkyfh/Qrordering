-- 103_attendance_commission.sql
-- FITUR ROADMAP-4 — Absensi (jam kerja) + Komisi karyawan.
--
-- Absensi TERPISAH dari shifts (shift = kas; absensi = jam kerja) supaya semua
-- role (termasuk owner/admin/manajer yang tak buka kas) bisa mencatat jam kerja.
-- Komisi = aturan (persen omzet / flat per order) yang dihitung dari
-- v_kasir_performance (sudah net refund) per staf.

-- ══ ABSENSI ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS attendances (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  staff_id   UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  clock_in   TIMESTAMPTZ NOT NULL DEFAULT now(),
  clock_out  TIMESTAMPTZ,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_attendances_staff  ON attendances(staff_id, clock_in DESC);
CREATE INDEX IF NOT EXISTS idx_attendances_outlet ON attendances(outlet_id, clock_in DESC);

ALTER TABLE attendances ENABLE ROW LEVEL SECURITY;

-- Baca: milik sendiri, atau owner, atau manajer+ (rank>=2) di outlet sama.
DROP POLICY IF EXISTS "attendances_select" ON attendances;
CREATE POLICY "attendances_select" ON attendances
  FOR SELECT TO authenticated
  USING (
    staff_id = auth.uid()
    OR is_owner()
    OR (auth_rank() >= 2 AND outlet_id = auth_outlet_id())
  );

GRANT SELECT ON attendances TO authenticated;
-- Tulis hanya via RPC (SECURITY DEFINER) → tak ada policy INSERT/UPDATE langsung.

-- Clock-in: idempotent (kembalikan sesi terbuka bila sudah ada).
CREATE OR REPLACE FUNCTION attendance_clock_in(p_note TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_staff  UUID := auth.uid();
  v_outlet UUID;
  v_open   UUID;
BEGIN
  IF v_staff IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT id INTO v_open FROM attendances
  WHERE staff_id = v_staff AND clock_out IS NULL
  ORDER BY clock_in DESC LIMIT 1;
  IF v_open IS NOT NULL THEN RETURN v_open; END IF;

  SELECT outlet_id INTO v_outlet FROM profiles WHERE id = v_staff;
  IF v_outlet IS NULL THEN RAISE EXCEPTION 'staff has no outlet'; END IF;

  INSERT INTO attendances (outlet_id, staff_id, note)
  VALUES (v_outlet, v_staff, p_note)
  RETURNING id INTO v_open;
  RETURN v_open;
END;
$$;

-- Clock-out: tutup sesi terbuka terakhir milik pemanggil.
CREATE OR REPLACE FUNCTION attendance_clock_out()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_staff UUID := auth.uid();
BEGIN
  IF v_staff IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  UPDATE attendances SET clock_out = now()
  WHERE id = (
    SELECT id FROM attendances
    WHERE staff_id = v_staff AND clock_out IS NULL
    ORDER BY clock_in DESC LIMIT 1
  );
END;
$$;

REVOKE ALL ON FUNCTION attendance_clock_in(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION attendance_clock_out()   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION attendance_clock_in(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION attendance_clock_out()   TO authenticated;

-- View laporan jam kerja.
DROP VIEW IF EXISTS v_attendance;
CREATE VIEW v_attendance AS
SELECT
  a.id,
  a.outlet_id,
  a.staff_id,
  p.full_name  AS staff_name,
  p.role       AS staff_role,
  a.clock_in,
  a.clock_out,
  a.note,
  (EXTRACT(EPOCH FROM (COALESCE(a.clock_out, now()) - a.clock_in)) / 3600.0)::numeric(10,2) AS hours,
  (a.clock_in AT TIME ZONE 'Asia/Jakarta')::date::text AS work_date
FROM attendances a
JOIN profiles p ON p.id = a.staff_id;

GRANT SELECT ON v_attendance TO authenticated;
ALTER VIEW v_attendance SET (security_invoker = on);

-- ══ KOMISI ═══════════════════════════════════════════════════════════════════
-- basis: 'percent' = % dari omzet yang di-handle staf; 'per_order' = flat per order.
-- scope: 'role' (berlaku utk semua staf role tsb) atau 'staff' (staf spesifik).
CREATE TABLE IF NOT EXISTS commission_rules (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  scope      TEXT NOT NULL CHECK (scope IN ('role', 'staff')),
  role       user_role,
  staff_id   UUID REFERENCES profiles(id) ON DELETE CASCADE,
  basis      TEXT NOT NULL CHECK (basis IN ('percent', 'per_order')),
  value      NUMERIC(12,2) NOT NULL CHECK (value >= 0),
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((scope = 'role' AND role IS NOT NULL) OR (scope = 'staff' AND staff_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_commission_rules_outlet ON commission_rules(outlet_id);

ALTER TABLE commission_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "commission_rules_select" ON commission_rules;
CREATE POLICY "commission_rules_select" ON commission_rules
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

-- Tulis: owner atau admin+ (rank>=3).
DROP POLICY IF EXISTS "commission_rules_write" ON commission_rules;
CREATE POLICY "commission_rules_write" ON commission_rules
  FOR ALL TO authenticated
  USING (is_owner() OR (auth_rank() >= 3 AND outlet_id = auth_outlet_id()))
  WITH CHECK (is_owner() OR (auth_rank() >= 3 AND outlet_id = auth_outlet_id()));

GRANT SELECT, INSERT, UPDATE, DELETE ON commission_rules TO authenticated;

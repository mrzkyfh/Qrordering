-- ============================================================
-- 021_outlets_constraints.sql
-- Fix dari API testing: tambah DB constraints yang hilang
-- ============================================================

-- Fix BUG-CAB-001: nama outlet harus minimal 2 karakter, max 100
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_outlet_name_length'
      AND conrelid = 'outlets'::regclass
  ) THEN
    ALTER TABLE outlets ADD CONSTRAINT chk_outlet_name_length
      CHECK (char_length(trim(name)) >= 2 AND char_length(name) <= 100);
  END IF;
END $$;

-- Fix BUG-CAB-004: tax_percent dan service_charge_percent harus 0-100
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_outlet_settings_ranges'
      AND conrelid = 'outlets'::regclass
  ) THEN
    ALTER TABLE outlets ADD CONSTRAINT chk_outlet_settings_ranges CHECK (
      settings IS NULL
      OR (
        COALESCE((settings->>'tax_percent')::numeric, 0) BETWEEN 0 AND 100
        AND COALESCE((settings->>'service_charge_percent')::numeric, 0) BETWEEN 0 AND 100
      )
    );
  END IF;
END $$;

-- Fix BUG-CAB-003: kasir tidak boleh update outlet (hanya owner & admin)
DROP POLICY IF EXISTS "outlets_update" ON outlets;
CREATE POLICY "outlets_update" ON outlets FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND id = auth_outlet_id())
);

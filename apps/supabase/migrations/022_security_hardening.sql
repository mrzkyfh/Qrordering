-- ============================================================
-- 022_security_hardening.sql
-- Fix privilege escalation + data integrity constraints
-- Found via API testing 2026-05-27
-- ============================================================

-- ── FIX BUG-PROF-001 & BUG-PROF-002 ─────────────────────────
-- profiles_update tanpa WITH CHECK memungkinkan kasir eskalasi
-- role ke 'owner' atau pindah outlet sendiri via direct API call.
-- WITH CHECK memastikan user tidak bisa mengubah role/outlet_id sendiri.
DROP POLICY IF EXISTS "profiles_update" ON profiles;
CREATE POLICY "profiles_update" ON profiles FOR UPDATE
USING (
  id = auth.uid()
  OR is_owner()
  OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
)
WITH CHECK (
  -- User update diri sendiri: role dan outlet_id harus tetap sama
  (
    id = auth.uid()
    AND role = (SELECT p.role FROM profiles p WHERE p.id = auth.uid())
    AND (outlet_id IS NOT DISTINCT FROM (SELECT p.outlet_id FROM profiles p WHERE p.id = auth.uid()))
  )
  OR is_owner()
  OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── FIX BUG-ING-001 ──────────────────────────────────────────
-- Kasir bisa langsung UPDATE stock_qty ingredients tanpa melalui
-- stock_transactions, membypass audit trail.
DROP POLICY IF EXISTS "ingredients_update" ON ingredients;
CREATE POLICY "ingredients_update" ON ingredients FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);

-- ── FIX BUG-EXP-001 ──────────────────────────────────────────
-- expense_date tidak boleh di masa depan (hanya frontend yang memblok).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_expense_date_not_future'
      AND conrelid = 'expenses'::regclass
  ) THEN
    ALTER TABLE expenses ADD CONSTRAINT chk_expense_date_not_future
      CHECK (expense_date <= CURRENT_DATE);
  END IF;
END $$;

-- ── FIX BUG-PROMO-001 ────────────────────────────────────────
-- Promo percentage > 100% diterima DB (hanya frontend yang memblok).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_promo_percentage_range'
      AND conrelid = 'promos'::regclass
  ) THEN
    ALTER TABLE promos ADD CONSTRAINT chk_promo_percentage_range CHECK (
      type != 'percentage' OR (value >= 0 AND value <= 100)
    );
  END IF;
END $$;

-- ── FIX BUG-PROMO-002 ────────────────────────────────────────
-- end_date sebelum start_date diterima DB.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_promo_date_range'
      AND conrelid = 'promos'::regclass
  ) THEN
    ALTER TABLE promos ADD CONSTRAINT chk_promo_date_range CHECK (
      start_date IS NULL OR end_date IS NULL OR end_date >= start_date
    );
  END IF;
END $$;

-- ── FIX BUG-MENU-001 ─────────────────────────────────────────
-- Harga menu item negatif diterima DB.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_menu_item_price'
      AND conrelid = 'menu_items'::regclass
  ) THEN
    ALTER TABLE menu_items ADD CONSTRAINT chk_menu_item_price CHECK (price >= 0);
  END IF;
END $$;

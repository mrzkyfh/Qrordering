-- ============================================================
-- cleanup_demo_data.sql
-- Hapus semua data demo & simulasi yang dibuat oleh:
--   - seed_demo_data.sql
--   - simulate_transactions.sql
--
-- ⚠ HATI-HATI: ini destructive. Pastikan jalankan di lingkungan
--   yang benar (staging atau setelah backup production).
--
-- Marker yang dipakai cleanup:
--   - orders.order_number LIKE 'SIM-%'              (semua simulasi)
--   - menu_extras.name LIKE '%(DEMO)%'              (3 extras per outlet)
--   - promos.name LIKE '%(DEMO)%'                   (2 promos per outlet)
--   - vouchers.code LIKE 'DEMO-%'                   (4 voucher per outlet)
--   - loyalty_members.phone LIKE '08DEMO%'          (5 member per outlet)
--   - expenses.description LIKE '[DEMO]%'           (10 expense per outlet)
--   - shifts.notes = '[DEMO-SIM] Shift simulasi'    (1 shift per outlet)
--
-- Yang TIDAK dihapus:
--   - menu_recipes & ingredients.cost_per_unit (data dari §7-§8 seed
--     sulit dibedakan dari yang asli — kalau perlu reset, edit manual)
-- ============================================================

BEGIN;

-- ── 1. Hapus order tersimulasi (cascade ke order_items, order_item_options, payments) ──
DO $$
DECLARE
  v_order_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_order_count FROM orders WHERE order_number LIKE 'SIM-%';
  RAISE NOTICE 'Menghapus % order simulasi...', v_order_count;

  -- Hapus loyalty_transactions yang link ke order simulasi
  DELETE FROM loyalty_transactions
  WHERE order_id IN (SELECT id FROM orders WHERE order_number LIKE 'SIM-%');

  -- order_items, order_item_options, payments ikut terhapus via ON DELETE CASCADE
  DELETE FROM orders WHERE order_number LIKE 'SIM-%';

  RAISE NOTICE '✓ Order simulasi dihapus';
END $$;

-- ── 2. Reverse loyalty points yang ter-earn dari order simulasi ──
-- (sudah ter-handle di step 1 via DELETE loyalty_transactions, tapi saldo points
--  di loyalty_members tidak auto-rollback. Kita reset members DEMO ke nilai awal seed.)
UPDATE loyalty_members SET points = 1500  WHERE phone = '08DEMO00001';
UPDATE loyalty_members SET points = 6200  WHERE phone = '08DEMO00002';
UPDATE loyalty_members SET points = 350   WHERE phone = '08DEMO00003';
UPDATE loyalty_members SET points = 25000 WHERE phone = '08DEMO00004';
UPDATE loyalty_members SET points = 800   WHERE phone = '08DEMO00005';

-- ── 3. Reset usage_count promo & voucher demo ──
UPDATE promos   SET usage_count = 0 WHERE name LIKE '%(DEMO)%';
UPDATE vouchers SET usage_count = 0 WHERE code LIKE 'DEMO-%';

-- ── 4. Hapus shift simulasi ──
DELETE FROM shifts WHERE notes = '[DEMO-SIM] Shift simulasi';

-- ── 5. Hapus master data demo ──
-- 5a. menu_item_extras → terhapus via CASCADE saat menu_extras dihapus
-- 5b. menu_extra_options → terhapus via CASCADE
-- 5c. menu_extras
DELETE FROM menu_extras WHERE name LIKE '%(DEMO)%';

-- 5d. vouchers (sebelum promos karena vouchers.promo_id FK)
DELETE FROM vouchers WHERE code LIKE 'DEMO-%';

-- 5e. promos (vouchers sudah dihapus, juga ON CASCADE)
DELETE FROM promos WHERE name LIKE '%(DEMO)%';

-- 5f. loyalty_members (loyalty_transactions ikut CASCADE)
DELETE FROM loyalty_members WHERE phone LIKE '08DEMO%';

-- 5g. expenses
DELETE FROM expenses WHERE description LIKE '[DEMO]%';

COMMIT;

-- ── Verifikasi ───────────────────────────────────────────────
SELECT 'orders (SIM-)'        AS check, COUNT(*) AS sisa FROM orders          WHERE order_number LIKE 'SIM-%'
UNION ALL SELECT 'menu_extras (DEMO)',  COUNT(*) FROM menu_extras    WHERE name LIKE '%(DEMO)%'
UNION ALL SELECT 'promos (DEMO)',       COUNT(*) FROM promos         WHERE name LIKE '%(DEMO)%'
UNION ALL SELECT 'vouchers (DEMO-)',    COUNT(*) FROM vouchers       WHERE code LIKE 'DEMO-%'
UNION ALL SELECT 'loyalty_members',     COUNT(*) FROM loyalty_members WHERE phone LIKE '08DEMO%'
UNION ALL SELECT 'expenses (DEMO)',     COUNT(*) FROM expenses       WHERE description LIKE '[DEMO]%'
UNION ALL SELECT 'shifts (SIM)',        COUNT(*) FROM shifts         WHERE notes = '[DEMO-SIM] Shift simulasi';

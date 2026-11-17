-- ============================================================
-- 080_fix_orders_insert_status.sql
-- FIX REGRESI: migrasi 070 (B-1) membatasi INSERT orders hanya status 'draft',
-- padahal POS membuat order langsung 'confirmed' (walk-in & Kirim ke Dapur).
-- Akibatnya semua pembuatan order ditolak RLS (error 42501 "tidak punya izin").
--
-- Perbaikan: izinkan INSERT untuk status awal yang sah (draft & confirmed),
-- tetap blokir status lanjutan (paid/served/ready/preparing/cancelled/void/
-- refunded) yang hanya boleh dicapai via UPDATE, dan tetap paksa approved_by NULL
-- (kolom approved_by juga sudah di-REVOKE dari authenticated di 070).
-- ============================================================

DROP POLICY IF EXISTS "orders_insert" ON orders;
CREATE POLICY "orders_insert" ON orders FOR INSERT WITH CHECK (
  outlet_id = auth_outlet_id()
  AND (status IS NULL OR status IN ('draft', 'confirmed'))
  AND (approved_by IS NULL)
);

-- ── FIX: state-machine status — izinkan langsung ke 'paid' (tanpa antrian) ────
-- Disertakan di sini agar 080 mandiri: bila 078 belum ter-apply, transisi
-- confirmed/draft → paid akan ditolak ("invalid order status transition").
CREATE OR REPLACE FUNCTION validate_order_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  valid_next TEXT[];
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  CASE OLD.status
    WHEN 'draft'     THEN valid_next := ARRAY['confirmed','paid','cancelled','void'];
    WHEN 'confirmed' THEN valid_next := ARRAY['preparing','ready','served','paid','cancelled','void'];
    WHEN 'preparing' THEN valid_next := ARRAY['ready','served','paid','cancelled','void'];
    WHEN 'ready'     THEN valid_next := ARRAY['served','paid','cancelled','void'];
    WHEN 'served'    THEN valid_next := ARRAY['paid','void'];
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % → %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

-- ── FIX: sync_table_status harus SECURITY DEFINER ─────────────────────────────
-- Trigger ini meng-UPDATE restaurant_tables saat status order berubah. Tanpa
-- SECURITY DEFINER ia berjalan sebagai pemanggil; kasir/manajer tidak punya izin
-- UPDATE restaurant_tables (hanya owner/admin) → bayar order dine-in (ada meja)
-- gagal 42501. Definer membuatnya berjalan dgn hak pemilik fungsi.
CREATE OR REPLACE FUNCTION sync_table_status()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.table_id IS NOT NULL AND NEW.status IN ('confirmed', 'preparing', 'ready', 'served') THEN
    UPDATE restaurant_tables SET status = 'occupied' WHERE id = NEW.table_id;
  END IF;

  IF NEW.table_id IS NOT NULL AND NEW.status IN ('paid', 'cancelled', 'void') THEN
    IF NOT EXISTS (
      SELECT 1 FROM orders
      WHERE table_id = NEW.table_id
        AND id <> NEW.id
        AND status IN ('confirmed', 'preparing', 'ready', 'served')
    ) THEN
      UPDATE restaurant_tables SET status = 'available' WHERE id = NEW.table_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ── FIX: potong stok juga saat confirmed/paid (alur tanpa 'preparing') ────────
-- Sejak dapur dihilangkan, order langsung confirmed→paid tanpa melewati
-- 'preparing', sehingga stok tidak pernah terpotong. deduct_stock_for_order
-- idempoten (guard stock_deducted) jadi aman dipanggil di beberapa transisi.
CREATE OR REPLACE FUNCTION handle_order_stock_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Potong stok saat order berkomitmen (confirmed/preparing/paid) — sekali saja.
  IF NEW.status IN ('confirmed', 'preparing', 'paid')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM deduct_stock_for_order(NEW.id);
  END IF;

  -- Kembalikan stok saat dibatalkan/void (refund = status 'cancelled').
  IF NEW.status IN ('cancelled', 'void')
     AND OLD.status NOT IN ('cancelled', 'void') THEN
    PERFORM restore_stock_for_order(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

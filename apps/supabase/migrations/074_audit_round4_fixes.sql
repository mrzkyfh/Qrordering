-- ============================================================
-- 074_audit_round4_fixes.sql  — Perbaikan dari audit putaran-4
-- KRITIS : void diblokir untuk order 'paid' + explicit stock restore
-- TINGGI : apply_promo_usage cabut grant anon
-- TINGGI : trigger validasi harga item customer menu
-- TINGGI : anon order insert validasi outlet_id cocok dengan meja
-- TINGGI : UNIQUE index cegah double award loyalty points
-- MEDIUM : closing_cash tidak boleh negatif
-- MEDIUM : kasir tidak boleh punya 2 shift terbuka sekaligus
-- ============================================================

-- ── KRITIS: Void tidak boleh pada order 'paid' ────────────────────────────────
-- Order 'paid' harus melalui jalur Refund agar payment record ikut di-reverse.
-- Tambahkan juga explicit restore_stock agar tidak bergantung sepenuhnya pada
-- trigger yang sudah diganti-ganti beberapa kali selama development.

DROP FUNCTION IF EXISTS public.void_order_with_approval(UUID,TEXT,TEXT,UUID);
CREATE FUNCTION public.void_order_with_approval(
  p_order        UUID,
  p_reason       TEXT,
  p_approver_pin TEXT,
  p_approver_id  UUID DEFAULT NULL
)
RETURNS TABLE(approver_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approver_id   UUID;
  v_approver_name TEXT;
  v_outlet        UUID;
  v_status        order_status;
BEGIN
  IF p_approver_id IS NULL THEN
    RAISE EXCEPTION 'approver_id wajib diisi';
  END IF;

  SELECT outlet_id, status INTO v_outlet, v_status
  FROM orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order tidak ditemukan'; END IF;

  -- Blokir void pada order yang sudah dibayar → harus pakai Refund
  IF v_status = 'paid' THEN
    RAISE EXCEPTION 'Order sudah dibayar — gunakan Refund, bukan Void';
  END IF;
  IF v_status IN ('void', 'cancelled', 'refunded') THEN
    RAISE EXCEPTION 'Order sudah dibatalkan atau di-refund';
  END IF;

  SELECT _find_approver(v_outlet, p_approver_pin, p_approver_id) INTO v_approver_id;
  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION 'PIN tidak valid atau tidak berwenang';
  END IF;

  SELECT full_name INTO v_approver_name FROM profiles WHERE id = v_approver_id;

  UPDATE orders
  SET status      = 'void',
      void_reason = p_reason,
      approved_by = v_approver_id,
      updated_at  = now()
  WHERE id = p_order;

  -- Explicit stock restore — tidak bergantung pada trigger saja
  PERFORM restore_stock_for_order(p_order);

  RETURN QUERY SELECT v_approver_name;
END;
$$;

REVOKE ALL ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_order_with_approval(UUID,TEXT,TEXT,UUID) TO authenticated;


-- ── TINGGI: Cabut grant anon untuk apply_promo_usage ─────────────────────────
-- Tanpa ini, siapapun bisa exhaust usage_count promo tanpa melakukan order.
REVOKE EXECUTE ON FUNCTION public.apply_promo_usage(UUID, UUID) FROM anon, PUBLIC;


-- ── TINGGI: Validasi harga item dari customer menu ────────────────────────────
-- unit_price di order_items wajib >= harga katalog di menu_items.
-- Mencegah customer mengubah harga via DevTools/API sebelum submit.

CREATE OR REPLACE FUNCTION public.validate_order_item_price()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_catalog_price NUMERIC;
BEGIN
  SELECT price INTO v_catalog_price
  FROM menu_items
  WHERE id = NEW.menu_item_id AND is_available = true;

  IF v_catalog_price IS NULL THEN
    RAISE EXCEPTION 'Menu item tidak ditemukan atau tidak tersedia';
  END IF;

  IF NEW.unit_price < v_catalog_price THEN
    RAISE EXCEPTION 'unit_price tidak valid (% < harga katalog %)',
      NEW.unit_price, v_catalog_price;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_order_item_price ON order_items;
CREATE TRIGGER trg_validate_order_item_price
  BEFORE INSERT ON order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_order_item_price();


-- ── TINGGI: Anon order insert — outlet_id harus cocok dengan outlet meja ──────
DROP POLICY IF EXISTS "orders_insert_anon" ON orders;
CREATE POLICY "orders_insert_anon" ON orders
  FOR INSERT TO anon
  WITH CHECK (
    order_type = 'self_order'
    AND (
      table_id IS NULL
      OR EXISTS (
        SELECT 1 FROM restaurant_tables rt
        WHERE rt.id    = table_id
          AND rt.outlet_id = orders.outlet_id
          AND rt.is_active = true
      )
    )
  );


-- ── TINGGI: Cegah double award loyalty points ─────────────────────────────────
-- UNIQUE index pada (order_id) WHERE type='earn' sebagai backstop definitif.
-- Bahkan jika race condition melewati idempotency check, DB menolak INSERT ke-2.
CREATE UNIQUE INDEX IF NOT EXISTS uq_loyalty_earn_per_order
  ON loyalty_transactions (order_id)
  WHERE type = 'earn';


-- ── MEDIUM: closing_cash tidak boleh negatif ──────────────────────────────────
-- CATATAN: baris ini dulu ditulis `ADD CONSTRAINT IF NOT EXISTS`, sintaks yang
-- TIDAK ADA di PostgreSQL. Akibatnya migration ini selalu gagal di titik ini —
-- membatalkan seluruh transaksinya dan mematikan rantai migration dari DB
-- kosong, sehingga 075 (yang dibuat khusus untuk menambal ini) tak pernah
-- terjangkau. Statement di BAWAHnya (uq_shift_one_open_per_kasir) juga ikut tak
-- pernah jalan; itulah kenapa 075 membuatnya ulang.
--
-- Diperbaiki di tempat memakai pola DO block yang sama dengan 075, dan
-- IDEMPOTEN: aman dijalankan ulang di DB yang constraint-nya sudah ada (mis.
-- produksi, yang sudah menerapkan 075 manual). Setelah ini, 075 menjadi no-op.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_shifts_closing_cash'
      AND conrelid = 'shifts'::regclass
  ) THEN
    ALTER TABLE shifts
      ADD CONSTRAINT chk_shifts_closing_cash
      CHECK (closing_cash IS NULL OR closing_cash >= 0);
  END IF;
END;
$$;


-- ── MEDIUM: Satu kasir hanya boleh punya satu shift terbuka ───────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uq_shift_one_open_per_kasir
  ON shifts (outlet_id, kasir_id)
  WHERE end_time IS NULL;

-- 089_table_transfer_merge.sql
-- FITUR: Pindah Meja (transfer) & Gabung Bill (merge) untuk dine-in.
--
-- Bagian 1 — Pindah meja: trigger status-meja sebelumnya HANYA fire saat
-- `status` berubah, jadi mengubah `table_id` tak membebaskan meja lama /
-- menempati meja baru. Perluas agar juga fire saat `table_id` berubah.
--
-- Bagian 2 — Gabung bill: RPC memindahkan item + transaksi stok ke order
-- tujuan, menjumlahkan nilai uang (total tetap kekal), lalu void order sumber
-- (item sudah kosong → restore stok no-op) sekaligus membebaskan mejanya.

-- ── Bagian 1: sync_table_status handle pindah meja ──────────────────────────
CREATE OR REPLACE FUNCTION sync_table_status()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Pindah meja: bebaskan meja LAMA bila tak ada order aktif lain di sana.
  IF TG_OP = 'UPDATE'
     AND OLD.table_id IS DISTINCT FROM NEW.table_id
     AND OLD.table_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM orders
      WHERE table_id = OLD.table_id AND id <> NEW.id
        AND status IN ('confirmed', 'preparing', 'ready', 'served')
    ) THEN
      UPDATE restaurant_tables SET status = 'available' WHERE id = OLD.table_id;
    END IF;
  END IF;

  -- Meja (baru/aktif) → occupied.
  IF NEW.table_id IS NOT NULL AND NEW.status IN ('confirmed', 'preparing', 'ready', 'served') THEN
    UPDATE restaurant_tables SET status = 'occupied' WHERE id = NEW.table_id;
  END IF;

  -- Order selesai/batal → bebaskan meja bila tak ada order aktif lain.
  IF NEW.table_id IS NOT NULL AND NEW.status IN ('paid', 'cancelled', 'void') THEN
    IF NOT EXISTS (
      SELECT 1 FROM orders
      WHERE table_id = NEW.table_id AND id <> NEW.id
        AND status IN ('confirmed', 'preparing', 'ready', 'served')
    ) THEN
      UPDATE restaurant_tables SET status = 'available' WHERE id = NEW.table_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Perluas trigger agar juga fire saat table_id berubah.
DROP TRIGGER IF EXISTS trg_sync_table_status ON orders;
CREATE TRIGGER trg_sync_table_status
  AFTER UPDATE OF status, table_id ON orders
  FOR EACH ROW EXECUTE FUNCTION sync_table_status();

-- ── Bagian 2: RPC gabung order ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION merge_orders(p_source UUID, p_target UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_src orders%ROWTYPE;
  v_tgt orders%ROWTYPE;
  v_active TEXT[] := ARRAY['draft', 'confirmed', 'preparing', 'ready', 'served'];
BEGIN
  IF p_source = p_target THEN
    RAISE EXCEPTION 'Order sumber dan tujuan tidak boleh sama';
  END IF;

  SELECT * INTO v_src FROM orders WHERE id = p_source;
  SELECT * INTO v_tgt FROM orders WHERE id = p_target;
  IF v_src.id IS NULL OR v_tgt.id IS NULL THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- Izin: owner atau kasir pada outlet yang sama untuk kedua order.
  IF NOT (is_owner()
          OR (v_src.outlet_id = auth_outlet_id()
              AND v_tgt.outlet_id = auth_outlet_id())) THEN
    RAISE EXCEPTION 'Tidak berizin menggabung order ini';
  END IF;
  IF v_src.outlet_id <> v_tgt.outlet_id THEN
    RAISE EXCEPTION 'Order beda outlet tidak bisa digabung';
  END IF;

  -- Keduanya harus aktif (belum lunas/batal/void).
  IF NOT (v_src.status::text = ANY(v_active))
     OR NOT (v_tgt.status::text = ANY(v_active)) THEN
    RAISE EXCEPTION 'Hanya order aktif (belum lunas) yang bisa digabung';
  END IF;

  -- Sumber tak boleh sudah ada pembayaran (mis. split bayar sebagian).
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_source) THEN
    RAISE EXCEPTION 'Order sumber sudah punya pembayaran — tidak bisa digabung';
  END IF;

  -- Pindah item (order_item_options ikut karena mengacu order_item_id) +
  -- transaksi stok (jaga atribusi HPP & agar void sumber tak restore ganda).
  UPDATE order_items       SET order_id = p_target WHERE order_id = p_source;
  UPDATE stock_transactions SET order_id = p_target WHERE order_id = p_source;

  -- Jumlahkan nilai uang → total gabungan = total_src + total_tgt (kekal).
  UPDATE orders SET
    subtotal        = v_tgt.subtotal        + v_src.subtotal,
    discount_amount = v_tgt.discount_amount + v_src.discount_amount,
    tax_amount      = v_tgt.tax_amount      + v_src.tax_amount,
    service_charge  = v_tgt.service_charge  + v_src.service_charge,
    total_amount    = v_tgt.total_amount    + v_src.total_amount,
    updated_at      = now()
  WHERE id = p_target;

  -- Void sumber (item sudah kosong → restore stok no-op) + bebaskan mejanya
  -- (via trigger sync_table_status).
  UPDATE orders SET
    status      = 'void',
    void_reason = 'Digabung ke order ' || v_tgt.order_number,
    updated_at  = now()
  WHERE id = p_source;

  RETURN jsonb_build_object(
    'merged_into', p_target,
    'source_voided', p_source
  );
END;
$$;

REVOKE ALL ON FUNCTION merge_orders(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION merge_orders(UUID, UUID) TO authenticated;

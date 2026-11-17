-- ============================================================
-- 076_audit_round5_fixes.sql — Perbaikan regresi dari audit putaran-5
-- A4 (TINGGI) : apply_promo_usage wajib order_id + idempotency, re-grant anon
--               (REVOKE di 074 merusak promo customer-menu → usage tak naik)
-- A1b (MEDIUM): trigger harga lepas syarat is_available agar offline-replay &
--               order historis tidak gagal sinkron; cukup validasi harga.
-- ============================================================

-- ── A1b: validate_order_item_price — hanya validasi harga, tanpa is_available ─
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
  WHERE id = NEW.menu_item_id;

  -- Item tidak ada di katalog → tolak (mencegah injeksi item palsu).
  IF v_catalog_price IS NULL THEN
    RAISE EXCEPTION 'Menu item tidak ditemukan';
  END IF;

  -- unit_price boleh >= harga katalog (variant/extra menambah), tidak boleh di bawah.
  IF NEW.unit_price < v_catalog_price THEN
    RAISE EXCEPTION 'unit_price tidak valid (% < harga katalog %)',
      NEW.unit_price, v_catalog_price;
  END IF;

  RETURN NEW;
END;
$$;
-- Trigger sudah dibuat di 074; CREATE OR REPLACE FUNCTION cukup, trigger tetap pakai versi baru.


-- ── A4: apply_promo_usage — wajib order_id nyata + idempotency per order ───────
-- Tabel pencatat penggunaan promo per order. Mencegah double-count & exhaust
-- tanpa order. RLS aktif tanpa policy → hanya bisa diakses via RPC DEFINER ini.
CREATE TABLE IF NOT EXISTS public.promo_usages (
  order_id   UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  promo_id   UUID REFERENCES promos(id) ON DELETE CASCADE,
  voucher_id UUID REFERENCES vouchers(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.promo_usages ENABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS public.apply_promo_usage(UUID, UUID);
CREATE FUNCTION public.apply_promo_usage(
  p_promo_id   UUID,
  p_voucher_id UUID DEFAULT NULL,
  p_order_id   UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_promo_limit    INTEGER;
  v_promo_count    INTEGER;
  v_promo_end_date DATE;
  v_voucher_limit  INTEGER;
  v_voucher_count  INTEGER;
BEGIN
  -- Wajib order nyata: tidak bisa exhaust promo tanpa transaksi.
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id wajib diisi';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id) THEN
    RAISE EXCEPTION 'Order tidak ditemukan';
  END IF;

  -- ── Promo ──
  IF p_promo_id IS NOT NULL THEN
    -- FOR UPDATE menserialisasi panggilan konkuren untuk promo yang sama.
    SELECT usage_limit, usage_count, end_date
    INTO v_promo_limit, v_promo_count, v_promo_end_date
    FROM promos WHERE id = p_promo_id FOR UPDATE;

    -- Idempotency: skip jika promo ini sudah dicatat untuk order ini.
    IF NOT EXISTS (
      SELECT 1 FROM promo_usages
      WHERE promo_id = p_promo_id AND order_id = p_order_id
    ) THEN
      IF v_promo_end_date IS NOT NULL AND v_promo_end_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'Promo sudah kedaluwarsa';
      END IF;
      IF v_promo_limit IS NOT NULL AND v_promo_count >= v_promo_limit THEN
        RAISE EXCEPTION 'Promo sudah mencapai batas penggunaan';
      END IF;

      INSERT INTO promo_usages (order_id, promo_id) VALUES (p_order_id, p_promo_id);
      UPDATE promos SET usage_count = usage_count + 1, updated_at = NOW()
      WHERE id = p_promo_id;
    END IF;
  END IF;

  -- ── Voucher ──
  IF p_voucher_id IS NOT NULL THEN
    SELECT usage_limit, usage_count
    INTO v_voucher_limit, v_voucher_count
    FROM vouchers WHERE id = p_voucher_id FOR UPDATE;

    IF NOT EXISTS (
      SELECT 1 FROM promo_usages
      WHERE voucher_id = p_voucher_id AND order_id = p_order_id
    ) THEN
      IF v_voucher_limit IS NOT NULL AND v_voucher_count >= v_voucher_limit THEN
        RAISE EXCEPTION 'Voucher sudah mencapai batas penggunaan';
      END IF;

      INSERT INTO promo_usages (order_id, voucher_id) VALUES (p_order_id, p_voucher_id);
      UPDATE vouchers SET usage_count = usage_count + 1
      WHERE id = p_voucher_id;
    END IF;
  END IF;
END;
$$;

-- Re-grant: customer self-order (anon) butuh ini, tapi sekarang wajib order_id valid.
REVOKE ALL ON FUNCTION public.apply_promo_usage(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_promo_usage(UUID, UUID, UUID) TO anon, authenticated;

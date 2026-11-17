-- ============================================================
-- 039_order_item_options.sql
-- Tabel pencatatan opsi extra yang dipilih per order item
-- + view agregasi penjualan sub extra
--
-- CATATAN NOMOR: dulu bernomor 038, sehingga berjalan SEBELUM
-- 038_menu_extras_schema.sql (dulu 039) yang membuat tabel menu_extras —
-- padahal FK di bawah bergantung padanya. Nomornya ditukar; lihat penjelasan
-- lengkap di header 038_menu_extras_schema.sql.
-- ============================================================

-- ── 1. Tabel pencatatan opsi extra per order item ────────────

CREATE TABLE IF NOT EXISTS order_item_options (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id        UUID NOT NULL REFERENCES order_items(id) ON DELETE CASCADE,
  menu_extra_id        UUID NOT NULL REFERENCES menu_extras(id) ON DELETE CASCADE,
  menu_extra_option_id UUID NOT NULL REFERENCES menu_extra_options(id) ON DELETE CASCADE,
  -- Snapshot nama saat order dibuat (agar report akurat walau nama berubah)
  extra_name           TEXT NOT NULL,
  option_name          TEXT NOT NULL,
  price                NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_oio_order_item   ON order_item_options(order_item_id);
CREATE INDEX IF NOT EXISTS idx_oio_extra        ON order_item_options(menu_extra_id);
CREATE INDEX IF NOT EXISTS idx_oio_extra_option ON order_item_options(menu_extra_option_id);

ALTER TABLE order_item_options ENABLE ROW LEVEL SECURITY;

-- Semua authenticated bisa baca (laporan)
CREATE POLICY "oio_select" ON order_item_options FOR SELECT TO authenticated USING (TRUE);

-- Anon bisa insert (self-order)
CREATE POLICY "oio_insert_anon" ON order_item_options FOR INSERT TO anon
  WITH CHECK (TRUE);

-- Authenticated bisa insert (kasir)
CREATE POLICY "oio_insert_auth" ON order_item_options FOR INSERT TO authenticated
  WITH CHECK (TRUE);

-- ── 2. View agregasi penjualan sub extra ─────────────────────

DROP VIEW IF EXISTS v_extra_option_sales;

CREATE VIEW v_extra_option_sales AS
SELECT
  o.outlet_id,
  me.id                                                    AS extra_id,
  COALESCE(oio.extra_name, me.name)                        AS extra_name,
  meo.id                                                   AS option_id,
  COALESCE(oio.option_name, meo.name)                      AS option_name,
  meo.price                                                AS option_price,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::date::text   AS sale_date,
  COUNT(oio.id)::integer                                   AS qty_selected,
  COALESCE(SUM(oio.price * oi.quantity), 0)::numeric       AS total_revenue
FROM menu_extras me
JOIN menu_extra_options meo ON meo.extra_id = me.id
LEFT JOIN order_item_options oio ON oio.menu_extra_option_id = meo.id
LEFT JOIN order_items oi ON oi.id = oio.order_item_id
LEFT JOIN orders o ON o.id = oi.order_id AND o.status = 'paid'
GROUP BY
  o.outlet_id, me.id, COALESCE(oio.extra_name, me.name),
  meo.id, COALESCE(oio.option_name, meo.name), meo.price, sale_date;

GRANT SELECT ON v_extra_option_sales TO authenticated;

COMMENT ON VIEW v_extra_option_sales IS
  'Agregasi penjualan per sub-extra (opsi). '
  'Menampilkan semua opsi yang dikonfigurasi; qty_selected=0 jika belum pernah dipilih.';
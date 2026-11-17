-- ============================================================
-- 049_order_number_daily_unique.sql
-- Fix BUG: "duplicate" saat simpan draf / buat order.
--
-- Sebab: get_next_order_number (029) reset counter TIAP HARI (001,002,...),
-- tapi unique constraint orders = UNIQUE(outlet_id, order_number) TANPA tanggal.
-- Akibatnya order_number hari ini (mis. '001') bentrok dengan '001' hari
-- sebelumnya untuk outlet yang sama → unique_violation.
--
-- Solusi: order_number cukup unik PER OUTLET PER HARI.
-- Tambah kolom order_seq_date (tanggal Asia/Jakarta), ganti constraint.
-- Aman dijalankan ulang.
-- ============================================================

-- 1) Kolom tanggal urutan (default = hari ini Asia/Jakarta saat insert)
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS order_seq_date DATE;

-- Backfill dari created_at (zona Asia/Jakarta)
UPDATE orders
SET order_seq_date = (created_at AT TIME ZONE 'Asia/Jakarta')::date
WHERE order_seq_date IS NULL;

ALTER TABLE orders
  ALTER COLUMN order_seq_date SET DEFAULT (NOW() AT TIME ZONE 'Asia/Jakarta')::date;

-- 2) Hapus unique lama yang hanya (outlet_id, order_number), apa pun namanya
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'orders'::regclass
      AND con.contype = 'u'
      AND (
        SELECT array_agg(a.attname::text ORDER BY a.attname::text)
        FROM unnest(con.conkey) k
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k
      ) = ARRAY['order_number','outlet_id']
  LOOP
    EXECUTE format('ALTER TABLE orders DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

-- 3) Unique baru: per outlet, per hari
ALTER TABLE orders
  DROP CONSTRAINT IF EXISTS orders_outlet_ordernum_day_key;
ALTER TABLE orders
  ADD CONSTRAINT orders_outlet_ordernum_day_key
  UNIQUE (outlet_id, order_number, order_seq_date);

COMMENT ON COLUMN orders.order_seq_date IS
  'Tanggal (Asia/Jakarta) untuk penomoran harian; bagian dari unique order_number per hari.';

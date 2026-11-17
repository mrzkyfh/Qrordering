-- Fix sintaks: ADD CONSTRAINT IF NOT EXISTS tidak didukung PostgreSQL.
-- Gunakan DO block untuk cek keberadaan constraint sebelum add.

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

-- Index IF NOT EXISTS sudah didukung PostgreSQL, ini aman.
CREATE UNIQUE INDEX IF NOT EXISTS uq_shift_one_open_per_kasir
  ON shifts (outlet_id, kasir_id)
  WHERE end_time IS NULL;

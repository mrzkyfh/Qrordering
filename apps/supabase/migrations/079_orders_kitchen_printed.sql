-- Penanda tiket dapur sudah dicetak (cegah cetak ganda saat "Kirim ke Dapur"
-- lalu order dibayar). Diset true oleh aplikasi setelah tiket berhasil dicetak.
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS kitchen_printed BOOLEAN NOT NULL DEFAULT false;

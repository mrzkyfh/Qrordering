-- 112_local_receipt_no.sql
-- Simpan nomor struk LOKAL yang dicetak perangkat sebelum server menomori.
--
-- Konteks: sejak "cetak dulu, sinkron belakangan", struk keluar SEBELUM order
-- sampai ke server, jadi order_number (get_next_order_number, atomik & unik per
-- outlet per hari) BELUM ada saat kertas keluar. Yang tercetak di struk
-- pelanggan adalah nomor lokal per perangkat (mis. 'A7-014').
--
-- Kolom ini menjembatani keduanya: saat pelanggan komplain sambil membawa struk
-- bertuliskan 'A7-014', kasir/owner bisa menemukan ordernya di server. Tanpa ini
-- nomor di kertas tidak merujuk apa pun yang tersimpan.
--
-- Ramping: TEXT pendek (~6 byte/order), NULL untuk order yang tidak dicetak dari
-- perangkat (mis. self-order QR). Ikut terhapus oleh prune_old_orders (110).
--
-- TIDAK unik: perangkat berbeda bisa memakai kode yang sama (kode device
-- di-generate acak lokal, tanpa koordinasi server). Nomor lokal adalah PETUNJUK
-- pencarian, bukan identitas — identitas tetap orders.id / order_number.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS local_receipt_no TEXT;

COMMENT ON COLUMN public.orders.local_receipt_no IS
  'Nomor struk lokal per perangkat yang tercetak sebelum sinkron (mis. A7-014). '
  'Untuk melacak order dari struk fisik. Tidak unik; identitas resmi = order_number.';

-- Pencarian "cari order dari nomor struk" per outlet. Partial index: hanya baris
-- yang benar-benar punya nomor lokal → indeks tetap kecil.
CREATE INDEX IF NOT EXISTS idx_orders_local_receipt_no
  ON public.orders (outlet_id, local_receipt_no)
  WHERE local_receipt_no IS NOT NULL;
  

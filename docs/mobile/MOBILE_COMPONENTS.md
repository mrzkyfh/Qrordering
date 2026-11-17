# Mobile Components

## Komponen aktif

| Area | Komponen |
|---|---|
| Auth | Login perangkat, pemilih staf, clock-in PIN, lease otorisasi |
| POS | Menu, keranjang, meja, pembayaran, shift, laporan kasir |
| Orders | Daftar order, status, void/refund, cetak ulang |
| Customer | Scan QR dan menu pelanggan |
| Printing | Struk, tiket dapur/bar, routing kategori, antrean dan autoprint |
| Settings | Perangkat, printer, order online, dan monitoring |

Role manusia aktif adalah Owner, Admin, Manajer, dan Kasir. Admin dan Manajer
setara pada cabang sendiri. Tidak ada login, shell, queue, atau profile khusus
operator produksi.

Printer dan tiket dapur tetap aktif sebagai target cetak dari aplikasi Kasir.
Penghapusan role akun tidak boleh menghapus kitchen_print.dart,
kitchen_ticket_builder.dart, konfigurasi dapurEnabled, ataupun pengujian
printer.

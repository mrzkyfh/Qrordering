# Mobile Architecture — QrOrdering

Aplikasi Flutter adalah POS bersama untuk Owner, Admin, Manajer, dan Kasir.
Tidak ada akun atau route khusus operator produksi.

## Role dan routing

| Role | Akses |
|---|---|
| Owner | POS lintas outlet yang dipilih dan administrasi penuh melalui web |
| Admin | POS dan administrasi cabang sendiri |
| Manajer | Setara Admin pada cabang sendiri |
| Kasir | POS, order, pembayaran, shift, dan printer pada cabang sendiri |

Route mobile aktif berada di /kasir/*, dengan /scan dan /menu/:tableToken
untuk pemesanan pelanggan. Role manusia melakukan clock-in melalui akun
Perangkat Cabang dan PIN.

## Alur produksi

Kasir mengirim order, lalu aplikasi mencetak tiket sesuai routing stasiun dan
kategori. Printer dapur, printer bar, tiket void, antrean cetak, serta cetak
ulang tetap merupakan bagian dari POS. Semua fungsi tersebut berdiri sendiri
dan tidak membutuhkan role akun khusus.

## Komponen utama

- features/auth: login perangkat, clock-in PIN, dan lease otorisasi.
- features/pos: menu, keranjang, pembayaran, shift, dan konfigurasi printer.
- features/orders: daftar order, status, void/refund, dan cetak ulang tiket.
- features/customer_menu: pemesanan QR.
- shared/services/kitchen_print.dart: routing dan eksekusi tiket produksi.
- shared/services/printer_service.dart: koneksi, antrean, dan konfigurasi
  printer.

Isolasi outlet dan otorisasi akhir ditegakkan oleh RLS/RPC Supabase.

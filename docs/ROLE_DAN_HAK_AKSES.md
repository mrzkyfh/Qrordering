# Role & Hak Akses — POS Time420s

Dokumen ini adalah acuan role aktif untuk owner-panel, aplikasi mobile, dan
aturan database. Sistem hanya memiliki role manusia **Owner, Admin, Manajer,
dan Kasir**. Akun teknis Perangkat Cabang memakai role internal `pelanggan` dan
tidak tampil sebagai staf.

> Printer dapur, tiket dapur, routing stasiun, dan tombol **Ke Dapur** adalah
> fitur operasional Kasir. Fitur tersebut tetap tersedia dan bukan role akun.

## Hierarki

| Role | Rank | Cakupan |
|---|---:|---|
| Owner | 4 | Seluruh cabang dan konfigurasi bisnis |
| Admin | 3 | Seluruh administrasi pada cabang sendiri |
| Manajer | 3 | Setara Admin pada cabang sendiri |
| Kasir | 1 | Transaksi dan shift pada cabang sendiri |

Admin dan Manajer mempunyai hak yang sama. Keduanya tidak dapat mengelola
Owner atau akun setingkat, dan tidak dapat mengakses cabang lain.

## Cara login

| Role | Owner-panel web | Mobile POS |
|---|---|---|
| Owner | Email + password | Clock-in PIN pada cabang yang dipilih |
| Admin | Email + password opsional | Clock-in PIN pada cabangnya |
| Manajer | Email + password opsional | Clock-in PIN pada cabangnya |
| Kasir | Tidak tersedia | Clock-in PIN pada cabangnya |

Tablet login lebih dahulu memakai Akun Perangkat Cabang, kemudian staf memilih
nama dan memasukkan PIN empat digit. Salah PIN lima kali mengunci percobaan
selama lima menit. PIN disimpan dalam bentuk hash.

## Hak akses

| Area | Owner | Admin | Manajer | Kasir |
|---|:---:|:---:|:---:|:---:|
| Monitoring seluruh cabang | Ya | Tidak | Tidak | Tidak |
| Master data dan pengaturan outlet | Ya | Cabang sendiri | Cabang sendiri | Tidak |
| Laporan outlet | Ya | Cabang sendiri | Cabang sendiri | Tutup kasir sendiri |
| Buat dan proses order | Ya | Ya | Ya | Ya |
| Pembayaran, shift, dan cetak struk | Ya | Ya | Ya | Ya |
| Tiket dan printer dapur | Ya | Ya | Ya | Ya |
| Catat pengeluaran | Ya | Ya | Ya | Tidak |
| Menyetujui void/refund | Ya | Ya | Ya | Sesuai `can_refund` |

Isolasi cabang ditegakkan oleh RLS database, bukan hanya tampilan aplikasi.

## Manajemen staf dan perangkat

| Pembuat | Role yang dapat dibuat | Cakupan |
|---|---|---|
| Owner | Admin, Manajer, Kasir, Akun Perangkat | Cabang mana pun |
| Admin | Kasir, Akun Perangkat | Cabang sendiri |
| Manajer | Kasir, Akun Perangkat | Cabang sendiri |
| Kasir | Tidak ada | — |

Penghapusan staf mensyaratkan rank pemanggil lebih tinggi dari target. Selain
Owner, pemanggil dan target wajib berada pada cabang yang sama.

## PIN dan approval

- Owner dapat mengatur PIN semua role.
- Admin dan Manajer dapat mengatur PIN sesama level serta Kasir di cabang yang
  sama, tetapi tidak dapat mengubah role/outlet/status akun setingkat.
- Kasir dapat mengganti PIN sendiri.
- Void dan refund oleh Kasir meminta PIN Owner/Admin/Manajer, kecuali
  `can_refund` untuk Kasir tersebut diaktifkan.

## Implementasi database

- `199_admin_manajer_access_equivalence.sql` menyetarakan otorisasi Admin dan
  Manajer.
- `200_retire_legacy_dapur_role.sql` mengonversi akun peninggalan menjadi Kasir
  dan mencegah nilai role lama dipakai kembali.
- Printer dan tiket dapur tidak menggunakan `profiles.role`, sehingga tidak
  terpengaruh oleh penghapusan role akun tersebut.

<section class="cover">
  <img class="cover-logo" src="../owner-panel/src/assets/logo.png" alt="Logo Time420s">
  <p class="eyebrow">MODUL PENGGUNAAN RESMI</p>
  <h1>Time420s</h1>
  <p class="cover-subtitle">Web Owner Panel, Aplikasi Kasir, Menu Digital Pelanggan, Persediaan, Laporan, dan Perangkat Cetak</p>
  <div class="cover-meta">
    <p><strong>Versi dokumen</strong> 2.0</p>
    <p><strong>Diperbarui</strong> 24 Juli 2026</p>
    <p><strong>Ditujukan untuk</strong> Owner, Admin, Manajer, dan Kasir</p>
  </div>
  <p class="cover-note">Panduan operasional untuk penggunaan harian dan proses onboarding outlet.</p>
</section>

<div class="page-break"></div>

# Tentang modul ini

Modul ini menjelaskan cara menggunakan Time420s dari tahap persiapan outlet sampai operasional harian. Nama menu, tombol, dan alur mengikuti versi aplikasi yang berlaku saat dokumen ini diterbitkan.

Time420s terdiri dari tiga bagian utama:

1. **Web Owner Panel** adalah halaman pengelolaan untuk mengatur data utama, cabang, sumber daya manusia, persediaan, dan laporan.
2. **Aplikasi POS (Point of Sale)** adalah aplikasi kasir untuk mencatat waktu masuk, membuat transaksi, mengelola pesanan, menerima pembayaran, mengatur giliran kerja, mencatat kehadiran, dan menggunakan printer.
3. **E-Menu pelanggan** adalah halaman menu digital yang dapat dibuka pelanggan dengan memindai kode respons cepat atau kode QR pada meja.

> **Penting:** tampilan menu dapat berbeda sesuai dengan peran pengguna. Jika suatu menu tidak muncul, periksa peran akun dan cabang yang dipilih sebelum menyimpulkan bahwa aplikasi mengalami gangguan.

## Cara menggunakan modul

- Pengguna baru sebaiknya membaca bagian **Mulai Cepat** dan **Persiapan Outlet** terlebih dahulu.
- Kasir dapat langsung menuju bagian **Operasional POS**.
- Admin operasional dapat membaca bagian **Produk**, **Persediaan**, **Pembayaran**, dan **Laporan**.
- Cara memasang dan mengatasi masalah printer dijelaskan pada bagian **Stasiun Cetak dan Printer**.
- Daftar pemeriksaan pada bagian akhir dapat dicetak dan digunakan sebagai prosedur operasional standar harian.

Nama tombol dan nama menu ditulis dengan huruf tebal, misalnya **Simpan** atau **Tambah Menu**. Istilah asing yang merupakan nama resmi fitur tetap ditulis seperti yang tampil di aplikasi. Arti istilah tersebut dijelaskan saat pertama kali digunakan dan dirangkum kembali pada bagian Glosarium.

# Daftar isi

[TOC]

# 1. Mulai cepat

Bagian ini adalah urutan minimum agar satu cabang dapat mulai menerima transaksi.

## 1.1 Daftar persiapan minimum

1. Pastikan akun Owner dapat masuk ke Web Owner Panel.
2. Buat atau periksa data cabang melalui **Cabang → Monitoring Cabang**.
3. Pilih cabang aktif dari pemilih cabang di bagian atas halaman.
4. Buat **Akun Perangkat** untuk tablet atau perangkat POS cabang.
5. Buat data staf Kasir, lalu tetapkan nomor identifikasi pribadi sebanyak empat digit.
6. Buat struktur produk: **Departemen → Kategori → Menu → Ekstra**.
7. Atur meja dan buat kode QR jika menggunakan E-Menu.
8. Aktifkan metode pembayaran yang diterima.
9. Atur pajak, biaya layanan, pembulatan, dan desain struk.
10. Buat stasiun cetak, lalu hubungkan kategori menu ke stasiun yang tepat.
11. Masuk ke aplikasi POS menggunakan Akun Perangkat.
12. Catat waktu masuk menggunakan nama staf dan nomor identifikasi pribadi.
13. Buka giliran kerja kasir atau **shift**, lalu masukkan modal awal.
14. Buat satu transaksi percobaan sampai pembayaran selesai dan struk tercetak.
15. Periksa laporan penjualan dan stok setelah transaksi uji.

## 1.2 Urutan konfigurasi yang disarankan

| Urutan | Modul | Hasil yang harus tersedia |
|---:|---|---|
| 1 | Cabang | Nama, alamat, telepon, kota, status aktif |
| 2 | Staf dan perangkat | Akun perangkat, staf, peran, nomor identifikasi pribadi |
| 3 | Produk | Departemen, kategori, menu, ekstra, paket |
| 4 | Persediaan | Bahan baku, satuan, pemasok, stok awal |
| 5 | Operasional | Meja, kode QR, penerimaan pesanan melalui internet |
| 6 | Pembayaran | Metode bayar, pajak, biaya, struk |
| 7 | Printer | Tujuan pencetakan dan printer fisik |
| 8 | Uji transaksi | Pesanan, pembayaran, pencetakan, laporan, stok |

> Jangan langsung melakukan transaksi sungguhan sebelum pengujian pembayaran, struk, printer dapur, dan penutupan giliran kerja berhasil.

<div class="no-page-break"></div>

# 2. Komponen sistem dan hak akses

## 2.1 Web Owner Panel

Web Owner Panel dibuka melalui aplikasi penjelajah internet, seperti Google Chrome atau Safari. Gunakan komputer atau tablet dengan layar yang cukup lebar agar tabel dan formulir lebih mudah dibaca.

Fungsi utama:

- Melihat performa semua cabang.
- Mengelola cabang dan staf.
- Mengelola menu, harga, ekstra, paket, dan ketersediaan.
- Mengatur stok, pemasok, pengeluaran, meja, kode QR, promosi, program loyalitas pelanggan, pembayaran, pajak, struk, dan stasiun cetak.
- Melihat serta mengekspor laporan.

## 2.2 Aplikasi POS

Aplikasi POS digunakan pada perangkat kasir. POS merupakan singkatan dari *Point of Sale* dan dalam modul ini berarti aplikasi kasir. Perangkat masuk menggunakan **Akun Perangkat**. Setelah itu, setiap staf memilih namanya dan memasukkan nomor identifikasi pribadi untuk mencatat waktu masuk.

Fungsi utama:

- Membuka dan menutup giliran kerja kasir.
- Membuat pesanan makan di tempat atau dibawa pulang.
- Menahan dan melanjutkan pesanan.
- Menerima pembayaran.
- Mengelola pesanan yang masih aktif.
- Membatalkan pesanan, mengembalikan pembayaran, mengembalikan sebagian pembayaran, memindahkan meja, dan menggabungkan tagihan sesuai izin pengguna.
- Mengatur printer lokal.
- Menyimpan transaksi dalam antrean ketika sambungan internet terputus, jika jenis transaksi tersebut mendukung penggunaan tanpa internet.

## 2.3 E-Menu pelanggan

E-Menu dibuka ketika pelanggan memindai kode QR pada meja. Pelanggan dapat memilih menu, menambah jumlah, menulis catatan jika diizinkan, dan mengirim pesanan.

E-Menu mengikuti:

- Status tersedia dan aktif pada menu.
- Jam penerimaan pesanan melalui internet.
- Kewajiban nama pelanggan.
- Izin catatan pesanan.
- Pajak, biaya layanan, dan pembulatan nilai transaksi pada cabang.
- Menu yang ditandai **Unggulan**.

## 2.4 Peran pengguna dan hak akses

| Peran | Akses utama | Batas utama |
|---|---|---|
| **Owner** | Semua cabang, pengaturan, laporan gabungan, staf, dan sistem | Tidak dibatasi ke satu cabang |
| **Admin** | Master data dan konfigurasi cabang yang ditetapkan | Tidak mengelola seluruh jaringan kecuali diberi cakupan |
| **Manajer** | Operasional, laporan, pesanan, pengeluaran, staf, dan absensi | Tidak mengubah sebagian besar data utama dan pengaturan |
| **Kasir** | Aplikasi kasir, pesanan, pembayaran, giliran kerja, dan absensi | Tindakan sensitif membutuhkan izin atau persetujuan atasan |
| **Perangkat** | Akun untuk masuk ke perangkat kasir | Bukan akun manusia dan tidak dipilih saat mencatat waktu masuk |

### Catatan tentang proses dapur

Versi operasional saat ini menggunakan **Routing Tiket Dapur dan printer stasiun**. Fitur ini mengarahkan tiket pesanan ke bagian yang tepat, misalnya Dapur, Bar, atau bagian Hidangan Penutup. Akun layar dapur yang terpisah bukan alur utama pada versi ini.

## 2.5 Cara masuk ke web dan aplikasi kasir

**Masuk ke Web Owner Panel:**

1. Masukkan alamat surel dan kata sandi.
2. Tekan **Masuk**.
3. Sistem menampilkan menu sesuai dengan peran pengguna.
4. Owner memilih cabang aktif melalui pemilih cabang di bagian atas halaman.

**Masuk ke aplikasi POS:**

1. Masukkan alamat surel dan kata sandi **Akun Perangkat**.
2. Pilih nama staf.
3. Masukkan nomor identifikasi pribadi sebanyak empat digit.
4. Setelah berhasil, aplikasi menampilkan menu sesuai dengan peran staf.

> Lima kali kesalahan memasukkan nomor identifikasi pribadi dapat mengunci akses sementara selama lima menit. Setiap staf harus menggunakan nomor miliknya sendiri.

# 3. Mengenal antarmuka dan tombol

## 3.1 Pemilih cabang

Nama cabang aktif tampil di bagian atas Web Owner Panel. Data pada bagian **OUTLET** mengikuti cabang yang sedang dipilih.

Sebelum membuat atau mengubah data:

1. Periksa nama cabang di header.
2. Ganti cabang bila diperlukan.
3. Tunggu data selesai dimuat.
4. Baru tekan tombol tambah, edit, atau simpan.

Kesalahan memilih cabang dapat membuat menu, pajak, printer, atau staff tercatat pada outlet yang salah.

## 3.2 Pola tombol

| Tampilan tombol | Arti umum |
|---|---|
| Merah/utama | Tindakan utama seperti Tambah, Simpan, Bayar, atau Proses |
| Outline | Tindakan sekunder seperti Batal, Kembali, atau pengaturan tambahan |
| Ikon pensil | Mengedit data |
| Ikon mata | Melihat detail atau mengubah visibilitas sesuai konteks |
| Ikon kunci | Mengatur PIN atau password |
| Ikon tempat sampah | Menghapus; biasanya meminta konfirmasi |
| Toggle | Mengaktifkan atau menonaktifkan status |

## 3.3 Status proses

- Tombol bertuliskan **Menyimpan...**, **Memproses...**, atau spinner berarti permintaan sedang berjalan.
- Jangan menekan tombol berulang kali saat proses belum selesai.
- Notifikasi hijau/normal berarti berhasil.
- Notifikasi merah berarti gagal dan harus dibaca sebelum mencoba ulang.
- Banner kesalahan data biasanya menyediakan tombol **Coba lagi**.

## 3.4 Penghapusan dan penonaktifan

Gunakan **Nonaktifkan** untuk data yang mungkin digunakan kembali. Gunakan **Hapus Permanen** hanya jika yakin karena tindakan tersebut dapat tidak bisa dikembalikan.

Data yang sudah memiliki riwayat transaksi biasanya diarsipkan atau dipertahankan agar laporan lama tidak rusak.

# 4. Persiapan outlet

## 4.1 Membuat dan mengatur cabang

Lokasi: **OWNER → Cabang → Monitoring Cabang**

1. Tekan **Tambah Cabang**.
2. Isi nama cabang.
3. Isi alamat, kota, dan nomor telepon.
4. Pastikan status cabang aktif.
5. Simpan.
6. Pilih cabang baru melalui pemilih cabang di header.

Pada daftar cabang, Owner dapat:

- Melihat status outlet.
- Mengubah detail cabang.
- Mengaktifkan atau menonaktifkan outlet.
- Membuka dashboard outlet.
- Menghapus cabang dengan konfirmasi ketat.

> Menghapus cabang adalah tindakan berisiko tinggi. Periksa transaksi, staff, menu, dan data historis sebelum melanjutkan.

## 4.2 Membuat Akun Perangkat

Lokasi: **OWNER → SDM → Manajemen Staff**

1. Tekan **Akun Perangkat**.
2. Pilih cabang.
3. Isi nama perangkat yang mudah dikenali, misalnya `POS Kasir Depan`.
4. Isi email login khusus perangkat.
5. Buat password yang kuat.
6. Simpan.

Rekomendasi:

- Satu perangkat utama memiliki satu akun perangkat.
- Jangan menggunakan email pribadi kasir sebagai Akun Perangkat.
- Catat hubungan nama perangkat dengan lokasi fisiknya.
- Jika perangkat hilang, nonaktifkan akun atau ubah password segera.

## 4.3 Membuat staff

Lokasi: **OWNER → SDM → Manajemen Staff**

1. Tekan **Tambah Staff**.
2. Isi nama lengkap.
3. Pilih role.
4. Pilih cabang untuk Manajer atau Kasir.
5. Masukkan PIN empat digit.
6. Isi nomor telepon bila diperlukan.
7. Untuk Admin atau Manajer yang membutuhkan akses web, isi email dan password.
8. Simpan.

### Filter staff per cabang

Gunakan **Filter cabang** di atas tabel:

- **Semua cabang** menampilkan seluruh akun.
- Nama cabang menampilkan akun yang ditugaskan khusus ke cabang itu.
- **Akun global** menampilkan akun seperti Owner yang berlaku di semua cabang.

### Pengaturan staff

Pada setiap baris tersedia tindakan sesuai role pengguna:

- Aktifkan/nonaktifkan staff.
- Beri atau cabut **Akses Refund**.
- Atur PIN.
- Reset password web bila akun memiliki email login.
- Edit nama, role, cabang, dan telepon.
- Hapus akun secara permanen.

## 4.4 Keamanan akun

- Gunakan PIN berbeda untuk setiap staff.
- Jangan menempelkan PIN di dekat kasir.
- Nonaktifkan staff yang sudah berhenti.
- Jangan berbagi akun Owner.
- Gunakan akun Admin atau Manajer untuk pekerjaan rutin.
- Ubah password perangkat jika perangkat berpindah lokasi atau operator.

# 5. Produk dan menu

## 5.1 Struktur produk

Struktur yang disarankan:

`Departemen → Kategori → Menu → Ekstra`

Contoh:

`Makanan → Ayam → Ayam Goreng → Level Pedas`

Paket/Bundling dikelola sebagai produk gabungan yang berisi beberapa komponen menu.

## 5.2 Departemen

Lokasi: **OUTLET → Produk → Departemen**

Departemen adalah kelompok besar untuk laporan dan organisasi menu, misalnya Makanan, Minuman, atau Merchandise.

1. Tekan **Tambah Departemen**.
2. Isi nama.
3. Atur status aktif.
4. Simpan.
5. Hubungkan kategori yang sesuai bila opsi tersedia.

Gunakan nama singkat dan konsisten agar laporan mudah dibaca.

## 5.3 Kategori

Lokasi: **OUTLET → Produk → Kategori**

1. Tekan **Tambah Kategori**.
2. Isi nama kategori.
3. Pilih departemen.
4. Atur ikon atau urutan jika diperlukan.
5. Pastikan status aktif.
6. Simpan.

Kategori dipakai untuk:

- Filter menu pada POS dan E-Menu.
- Laporan penjualan kategori.
- Routing tiket ke stasiun cetak.
- Pengelompokan perangkat printer.

## 5.4 Menu

Lokasi: **OUTLET → Produk → Menu**

### Menambah menu

1. Tekan **Tambah Menu**.
2. Unggah foto menu bila tersedia.
3. Isi **Nama Menu**.
4. Pilih **Kategori**.
5. Isi harga.
6. Isi deskripsi singkat.
7. Isi waktu masak dalam menit bila ingin mencatat estimasi.
8. Isi tags bila diperlukan.
9. Aktifkan **Tersedia**.
10. Aktifkan **Unggulan** bila produk perlu diprioritaskan.
11. Hubungkan ekstra yang dapat dipilih.
12. Tekan **Tambah** atau **Simpan Perubahan**.

### Arti Tersedia

- Aktif: menu dapat dipilih pada POS dan E-Menu.
- Nonaktif: menu tetap tersimpan, tetapi tidak dapat dipesan.

Gunakan status tidak tersedia untuk stok habis sementara. Jangan menghapus menu hanya karena sedang habis.

### Arti Unggulan

Menu Unggulan:

- Ditampilkan sebelum menu biasa.
- Tetap mengikuti filter kategori dan pencarian.
- Memiliki badge bintang **Unggulan** pada POS dan E-Menu pelanggan.
- Di antara sesama menu unggulan, urutan manual tetap dihormati.

Gunakan untuk menu signature, best seller, promosi utama, atau produk dengan prioritas penjualan.

### Arti tags

Tags adalah metadata seperti `pedas`, `baru`, atau `vegetarian`. Pada versi ini tags disimpan sebagai informasi klasifikasi dan belum menjadi filter pelanggan. Jangan menggunakan tags sebagai pengganti kategori atau toggle Unggulan.

### Foto menu

- Gunakan foto terang dan fokus.
- Rasio persegi atau mendekati persegi memberikan hasil paling konsisten.
- Hindari file yang terlalu besar.
- Pastikan foto sesuai produk yang dijual.

## 5.5 Ekstra

Lokasi: **OUTLET → Produk → Ekstra**

Ekstra digunakan untuk topping, ukuran, level pedas, pilihan saus, dan pilihan tambahan lain.

1. Tekan **Tambah Ekstra**.
2. Isi nama grup, misalnya `Level Pedas`.
3. Tambahkan minimal satu pilihan.
4. Isi harga tambahan setiap pilihan; gunakan nol jika gratis.
5. Atur apakah pilihan wajib.
6. Atur jumlah minimum/maksimum jika tersedia.
7. Simpan.
8. Hubungkan grup ekstra ke menu terkait melalui form Menu.

Lakukan transaksi uji untuk memastikan harga tambahan masuk ke subtotal dan tercetak pada tiket.

## 5.6 Paket/Bundling

Lokasi: **OUTLET → Produk → Paket / Bundling**

1. Tekan **Tambah Paket**.
2. Isi nama paket.
3. Isi harga jual paket.
4. Tambahkan minimal satu komponen menu.
5. Tentukan jumlah setiap komponen.
6. Simpan.

Paket berbeda dari promo. Paket memiliki item gabungan dan harga sendiri, sedangkan promo memberikan potongan berdasarkan ketentuan.

## 5.7 Checklist produk sebelum tayang

- Nama dan harga benar.
- Kategori benar.
- Foto tidak tertukar.
- Menu tersedia hanya jika benar-benar bisa dijual.
- Menu unggulan dipilih secukupnya.
- Ekstra terhubung ke menu yang tepat.
- Paket memiliki semua komponen.
- Tiket tercetak ke stasiun yang benar.
- Pajak dan biaya dihitung sesuai kebijakan outlet.

# 6. Persediaan dan inventori

## 6.1 Stok bahan baku

Lokasi: **OUTLET → Inventori → Stok Bahan Baku**

1. Tekan **Tambah Bahan Baku**.
2. Isi nama bahan.
3. Pilih satuan yang konsisten, misalnya gram, kilogram, mililiter, liter, atau pcs.
4. Isi stok awal.
5. Isi batas minimum.
6. Isi biaya satuan bila digunakan untuk HPP.
7. Simpan.

Jangan mencampur satuan pembelian dan satuan resep tanpa konversi yang jelas.

## 6.2 Penyesuaian stok

Gunakan penyesuaian untuk:

- Pembelian atau penerimaan bahan.
- Koreksi jumlah.
- Pemakaian di luar transaksi.
- Waste, rusak, atau kedaluwarsa.

Setiap penyesuaian harus memiliki alasan yang dapat diaudit. Hindari mengubah angka tanpa keterangan.

## 6.3 Supplier

Lokasi: **OUTLET → Inventori → Supplier**

Simpan:

- Nama supplier.
- Kontak.
- Telepon.
- Alamat atau catatan.

Gunakan nama yang konsisten agar riwayat pembelian mudah ditelusuri.

## 6.4 Stock Opname

Lokasi: **OUTLET → Inventori → Stok Opname**

1. Buat sesi opname.
2. Hitung stok fisik.
3. Masukkan jumlah aktual setiap bahan.
4. Periksa selisih sistem dan fisik.
5. Tambahkan catatan untuk selisih besar.
6. Finalisasi opname.

> Setelah finalisasi, hasil digunakan sebagai catatan resmi penyesuaian. Periksa semua angka sebelum menekan tombol finalisasi.

## 6.5 Resep dan HPP

Resep menghubungkan menu dengan bahan baku. Pastikan kuantitas bahan per porsi memakai satuan yang sama dengan master bahan.

Contoh:

| Menu | Bahan | Jumlah per porsi |
|---|---|---:|
| Ayam Goreng | Ayam | 1 pcs |
| Ayam Goreng | Minyak | 30 ml |
| Es Teh | Teh | 5 gram |
| Es Teh | Gula | 20 gram |

Transaksi yang diproses sistem akan memengaruhi stok sesuai resep dan aturan transaksi. Periksa **Laporan Stok** setelah transaksi uji.

## 6.6 Laporan stok dan waste

Lokasi:

- **Inventori → Laporan Stok**
- **Inventori → Laporan Waste**

Gunakan laporan untuk memeriksa:

- Saldo awal dan akhir.
- Penambahan dan pengurangan.
- Bahan kritis.
- Penyesuaian manual.
- Waste dan alasannya.

# 7. Meja, kode QR, dan pesanan pelanggan

## 7.1 Kelola meja

Lokasi: **OUTLET → Operasional → Kelola Meja**

1. Tekan **Tambah Meja**.
2. Isi nomor atau nama meja.
3. Isi area bila diperlukan, misalnya Indoor atau Lantai 2.
4. Isi kapasitas.
5. Pastikan meja aktif.
6. Simpan.

Gunakan penamaan unik. Jangan membuat dua meja aktif dengan identitas yang membingungkan.

## 7.2 Kode QR

Lokasi: **OUTLET → Operasional → QR Code**

1. Pilih meja.
2. Buat atau tampilkan QR.
3. Unduh QR.
4. Cetak dengan ukuran yang mudah dipindai.
5. Pasang pada meja yang sesuai.
6. Uji menggunakan kamera ponsel.

QR harus membuka outlet dan meja yang benar. Jangan menyalin QR satu meja ke meja lain.

## 7.3 Order Online

Lokasi aplikasi POS: **Pengaturan → Order Online**

Pengaturan yang tersedia meliputi:

- Terima pesanan online.
- Pembatasan jam operasional.
- Nama pelanggan wajib atau opsional.
- Izin catatan pesanan.
- Konfirmasi otomatis.

Uji order di dalam dan di luar jam operasional.

## 7.4 Alur pelanggan

1. Pelanggan memindai QR.
2. Sistem mengenali meja dan outlet.
3. Pelanggan melihat menu tersedia.
4. Menu unggulan muncul lebih dulu dengan badge.
5. Pelanggan memilih jumlah item.
6. Pelanggan membuka keranjang.
7. Pelanggan mengisi nama/catatan bila diminta.
8. Pelanggan memeriksa total.
9. Pelanggan mengirim order.
10. POS menerima order dan notifikasi sesuai konfigurasi.

# 8. Pembayaran, pajak, biaya, dan struk

## 8.1 Metode pembayaran

Lokasi web: **OUTLET → Pembayaran → Metode Pembayaran**
Lokasi POS: **Pengaturan → Pembayaran Nontunai**

Metode yang dapat digunakan mencakup:

- Tunai.
- QRIS.
- Debit.
- Kredit.
- E-wallet.
- Transfer.

Tunai dipertahankan sebagai jalur pembayaran dasar. Aktifkan hanya metode yang benar-benar diterima cabang.

## 8.2 Pajak

Lokasi: **OUTLET → Pembayaran → Pajak**

1. Isi nama pajak.
2. Isi persentase.
3. Pilih status aktif.
4. Pilih **Exclusive** jika pajak harus ditambahkan setelah harga produk dijumlahkan.
5. Pilih **Inclusive** jika pajak sudah termasuk di dalam harga produk.
6. Tentukan apakah pajak dihitung sebelum atau sesudah potongan harga, jika pilihan tersebut tersedia.
7. Pilih jenis pesanan yang dikenai pajak.
8. Periksa kembali persentase dan cara perhitungannya.
9. Tekan **Simpan**.

Lakukan transaksi nominal sederhana agar perhitungan mudah diperiksa.

## 8.3 Biaya dan service charge

Lokasi: **OUTLET → Pembayaran → Biaya**

Gunakan untuk mengatur biaya layanan atau komponen biaya lain yang memang berlaku. Pastikan kebijakan sesuai operasional dan informasi kepada pelanggan.

## 8.4 Pembulatan

Jika pembulatan digunakan, pilih nominal yang sesuai kebijakan outlet. Pembulatan dilakukan pada total sesuai konfigurasi sistem.

## 8.5 Struk

Lokasi web: **OUTLET → Pembayaran → Struk**
Lokasi POS: **Pengaturan → Struk & Biaya**

Konfigurasi dapat mencakup:

- Nama bisnis.
- Alamat dan telepon.
- Logo.
- Header.
- Field tambahan.
- Footer.
- Tampilan pajak dan service charge.
- Perataan dan gaya elemen.

Gunakan preview, simpan, lalu cetak transaksi uji pada printer sebenarnya.

# 9. Stasiun cetak dan printer

## 9.1 Apa itu stasiun cetak?

Stasiun cetak adalah **tujuan logis**, bukan printer fisik.

Contoh:

| Stasiun logis | Kategori yang diarahkan | Printer fisik |
|---|---|---|
| Dapur | Makanan, Snack | Printer dapur |
| Bar | Kopi, Minuman | Printer bar |
| Dessert | Dessert | Printer dessert |

Dengan pemisahan ini, kategori dapat diatur dari web dan setiap perangkat POS menghubungkan stasiun tersebut ke printer fisik di lokasi.

## 9.2 Membuat stasiun di web

Lokasi: **OUTLET → Pembayaran → Routing Tiket Dapur**

1. Tekan tambah stasiun.
2. Isi nama stasiun, misalnya `Dapur Utama`.
3. Pilih kategori menu yang harus masuk ke stasiun tersebut.
4. Atur urutan atau status bila tersedia.
5. Simpan.

Satu kategori sebaiknya memiliki tujuan yang jelas agar tiket tidak salah cetak.

## 9.3 Menghubungkan printer pada POS

Lokasi: **Pengaturan → Perangkat**

1. Tambahkan printer.
2. Pilih koneksi Bluetooth atau LAN.
3. Isi nama perangkat.
4. Tentukan peran printer, misalnya Struk atau Dapur.
5. Untuk printer dapur, pilih stasiun yang dibuat dari web.
6. Atur ukuran kertas.
7. Aktifkan jenis auto-print yang dibutuhkan.
8. Simpan.
9. Jalankan tes cetak.

## 9.4 Satu printer untuk beberapa peran

Satu printer fisik dapat digunakan untuk lebih dari satu peran jika konfigurasi dan kapasitas operasional memungkinkan. Namun untuk outlet sibuk, pisahkan printer Struk dan Dapur agar antrean tidak saling menghambat.

## 9.5 Auto-print

Periksa pengaturan:

- Auto-print saat pembayaran.
- **Cetak tiket saat order dikirim** untuk membuat tiket dapur secara otomatis ketika kasir menekan **Ke Dapur**.
- **Cetak tiket saat void** untuk mengirim pemberitahuan pembatalan ke stasiun dapur.
- Jumlah salinan.
- Kategori/stasiun tujuan.

Cetak manual tetap tersedia dari Daftar Order sesuai fungsi pada halaman.

Jika printer sedang terputus saat pencetakan, tiket disimpan dalam antrean cetak. Setelah printer kembali siap, buka pengaturan printer dan jalankan ulang antrean yang belum tercetak.

## 9.6 Troubleshooting printer

**Printer Bluetooth tidak ditemukan**

- Pastikan Bluetooth aktif.
- Pastikan printer menyala dan tidak terhubung ke perangkat lain.
- Berikan izin perangkat sekitar bila diminta Android.
- Hapus pasangan lama lalu pasangkan ulang.

**Printer LAN gagal**

- Pastikan POS dan printer berada pada jaringan yang sama.
- Periksa IP dan port.
- Hindari IP dinamis; gunakan reservasi DHCP atau IP tetap.
- Tes koneksi setelah perubahan router.

**Tiket masuk ke printer yang salah**

- Periksa kategori menu.
- Periksa mapping kategori pada Routing Tiket Dapur.
- Periksa stasiun yang dipilih pada printer POS.
- Pastikan tidak ada konfigurasi printer lama yang duplikat.

**Tiket tercetak dua kali**

- Periksa apakah printer yang sama tersimpan ganda.
- Periksa jumlah salinan.
- Periksa auto-print pada setiap peran.
- Periksa lebih dari satu perangkat POS yang mendengarkan order yang sama.

# 10. Promosi, kupon, program loyalitas, dan data pelanggan

## 10.1 Promosi dan kupon

Lokasi: **OUTLET → Promosi → Promo & Voucher**

Jenis utama:

- Potongan persentase.
- Potongan nominal tetap.

1. Tekan **Tambah Promo**.
2. Isi nama dan kode.
3. Pilih jenis diskon.
4. Isi nilai diskon.
5. Isi minimum transaksi bila diperlukan.
6. Isi batas maksimum diskon untuk persentase jika digunakan.
7. Atur periode aktif.
8. Atur batas penggunaan.
9. Aktifkan promo.
10. Simpan.

Paket atau gabungan menu dikelola melalui menu Produk, bukan sebagai jenis promosi.

## 10.2 Menggunakan promosi pada aplikasi kasir

1. Tambahkan item ke keranjang.
2. Masukkan kode promo.
3. Sistem memvalidasi cabang, periode, minimum transaksi, dan batas penggunaan.
4. Pastikan nilai diskon tampil pada ringkasan.
5. Lanjutkan pembayaran.

Jika isi keranjang berubah, sistem memvalidasi ulang promo. Promo yang tidak lagi memenuhi syarat akan dilepas.

## 10.3 Anggota program loyalitas

Lokasi: **OUTLET → Loyalty → Member Loyalty**

Gunakan halaman untuk:

- Mencari member.
- Memeriksa poin.
- Meninjau aktivitas loyalty.
- Mengelola data yang tersedia sesuai izin.

Pada aplikasi kasir, pencarian anggota dilakukan menggunakan nomor telepon. Pastikan nomor ditulis dengan format yang konsisten.

## 10.4 Data pelanggan dan CRM

Lokasi: **OUTLET → Loyalty → Pelanggan (CRM)**

CRM merupakan singkatan dari *Customer Relationship Management* atau pengelolaan hubungan pelanggan. Fitur ini membantu pengguna melihat riwayat dan informasi pelanggan. Gunakan data hanya untuk pekerjaan yang sah dan berikan akses hanya kepada pengguna yang memerlukannya.

<div class="no-page-break"></div>

# 11. Operasional aplikasi kasir

## 11.1 Masuk menggunakan akun perangkat

1. Buka aplikasi.
2. Masukkan alamat surel dan kata sandi Akun Perangkat.
3. Tunggu sampai halaman utama selesai dimuat.
4. Periksa nama cabang yang tampil.
5. Jika cabang salah, keluar dari aplikasi dan masuk kembali menggunakan akun perangkat untuk cabang yang benar.

## 11.2 Mencatat waktu masuk staf

1. Pilih nama staf yang akan menggunakan kasir.
2. Masukkan nomor identifikasi pribadi sebanyak empat digit.
3. Tekan tombol untuk mencatat waktu masuk.
4. Periksa nama pengguna aktif yang tampil di aplikasi.
5. Jika nama yang tampil salah, keluar dari sesi staf sebelum membuat transaksi.

## 11.3 Membuka giliran kerja kasir

1. Buka halaman Kasir atau halaman **Shift**.
2. Pilih **Buka Kasir** jika belum ada giliran kerja yang aktif.
3. Masukkan modal awal tunai.
4. Periksa kembali jumlah modal awal.
5. Konfirmasi pembukaan kasir.
6. Pastikan status giliran kerja berubah menjadi terbuka.

Satu kasir tidak boleh membuka dua giliran kerja aktif pada waktu yang sama.

## 11.4 Membuat pesanan

1. Tentukan jenis pesanan.
2. Pilih **Dine In** jika pelanggan makan di tempat.
3. Pilih **Takeaway** jika pesanan akan dibawa pulang.
4. Untuk pesanan makan di tempat, pilih meja yang digunakan pelanggan.
5. Pilih kategori atau gunakan kolom pencarian untuk menemukan menu.
6. Menu yang ditandai **Unggulan** tampil lebih dahulu.
7. Tekan menu untuk melihat pilihan atau menambahkannya ke keranjang.
8. Pilih varian atau ekstra jika tersedia.
9. Isi catatan jika pelanggan memiliki permintaan khusus.
10. Atur jumlah pesanan.
11. Periksa seluruh isi keranjang sebelum melanjutkan.

## 11.5 Tahan Pesanan

Gunakan **Tahan Pesanan** ketika pelanggan belum siap membayar atau transaksi harus dilanjutkan nanti.

1. Pastikan keranjang memiliki item.
2. Tekan **Tahan Pesanan**.
3. Isi identitas yang diperlukan.
4. Simpan.
5. Buka kembali dari daftar pesanan ditahan.

Jangan menggunakan tahan pesanan sebagai pengganti order aktif yang sudah dikirim ke dapur.

## 11.6 Mengirim order dan menambah pesanan

Untuk mengirim pesanan dari Daftar Order:

1. Buka **Daftar Order**.
2. Temukan pesanan yang masih berstatus Draft.
3. Tekan **Ke Dapur**.
4. Sistem mengubah status pesanan menjadi Dikonfirmasi.
5. Setelah status berhasil disimpan, sistem membuat tiket dapur secara otomatis.
6. Tiket dibagi ke printer Dapur berdasarkan stasiun dan kategori menu.
7. Jika printer terputus, tiket masuk antrean cetak dan tidak mengubah kembali status pesanan.

Pastikan peran **Dapur** dan pengaturan **Cetak tiket saat order dikirim** sudah aktif pada printer yang digunakan.

Order aktif dapat ditambahkan item melalui fungsi **Tambah Pesanan**. Item tambahan dicatat ke order yang sama tanpa membuat tagihan terpisah.

Order yang sudah dicetak tidak diedit bebas. Gunakan Tambah Pesanan, Void, atau Refund sesuai status transaksi agar audit tetap benar.

## 11.7 Pembayaran

1. Periksa item, jumlah, ekstra, catatan, meja, subtotal, diskon, pajak, dan service charge.
2. Tekan **Bayar**.
3. Pilih metode pembayaran.
4. Untuk tunai, masukkan nominal diterima dan periksa kembalian.
5. Untuk nontunai, pastikan transaksi eksternal benar-benar berhasil.
6. Konfirmasi pembayaran satu kali.
7. Tunggu status berhasil.
8. Cetak atau bagikan struk sesuai kebutuhan.

> Jangan menekan Bayar berulang kali. Sistem memiliki perlindungan transaksi, tetapi operator tetap harus menunggu hasil proses.

## 11.8 Pembayaran terpisah

Jika fitur split digunakan:

1. Buka order.
2. Pilih pembagian pembayaran.
3. Tentukan item atau nominal untuk masing-masing pembayaran.
4. Proses setiap bagian.
5. Finalisasi setelah seluruh total terpenuhi.

Jangan menutup order sebelum semua bagian pembayaran berhasil.

<div class="no-page-break"></div>

# 12. Pengelolaan pesanan

## 12.1 Daftar Order

Lokasi POS: **Daftar Order**
Lokasi web: **OUTLET → Pesanan → Daftar Pesanan**

Gunakan filter status, pencarian, atau periode untuk menemukan order.

Status umum:

| Status | Arti |
|---|---|
| Draft | Belum dikirim/dikonfirmasi |
| Confirmed | Diterima untuk diproses |
| Preparing | Sedang disiapkan |
| Ready | Siap disajikan/diambil |
| Served | Sudah disajikan |
| Paid | Sudah dibayar |
| Void | Dibatalkan |
| Refunded | Dikembalikan |

## 12.2 Pindah meja

1. Buka order dine-in aktif.
2. Pilih **Pindah Meja**.
3. Pilih meja tujuan yang sesuai.
4. Konfirmasi.
5. Pastikan nomor meja pada order berubah.

## 12.3 Gabung tagihan

1. Buka salah satu order dine-in aktif.
2. Pilih **Gabung**.
3. Pilih order tujuan.
4. Periksa kedua order.
5. Konfirmasi.

Setelah digabung, item berpindah ke order tujuan dan sumber diproses sesuai aturan audit sistem.

## 12.4 Void

Void digunakan untuk membatalkan order yang belum diselesaikan sebagai transaksi pembayaran final.

1. Buka order.
2. Pilih **Void**.
3. Isi alasan.
4. Masukkan PIN approver bila diminta.
5. Konfirmasi.

Approver harus Owner, Admin, Manajer, atau staff dengan izin yang sesuai.

Setelah Void berhasil disimpan:

- Printer Struk mencetak dokumen **STRUK VOID** yang berisi nomor order, daftar item, nilai transaksi, alasan pembatalan, nama pemberi persetujuan, dan waktu Void.
- Printer Dapur yang mengaktifkan **Cetak tiket saat void** menerima tiket dengan tanda **VOID** agar pesanan yang sudah dibatalkan tidak dilanjutkan.
- Jika printer sedang terputus, dokumen masuk antrean cetak. Void tetap sah dan tidak dijalankan ulang.
- Aplikasi menampilkan hasil apakah struk sudah tercetak, masuk antrean, atau belum memiliki printer Struk yang aktif.

## 12.5 Refund penuh

Refund digunakan setelah transaksi dibayar.

1. Buka order paid.
2. Pilih **Refund**.
3. Isi alasan.
4. Masukkan PIN approver.
5. Konfirmasi.
6. Lakukan pengembalian dana nyata sesuai metode pembayaran.

Sistem mencatat refund, tetapi proses pengembalian pada bank, QRIS, atau E-wallet dapat tetap memerlukan tindakan pada penyedia pembayaran.

## 12.6 Refund sebagian

1. Buka order paid.
2. Pilih **Refund Sebagian**.
3. Pilih item dan jumlah yang dikembalikan.
4. Periksa nominal.
5. Isi alasan dan persetujuan.
6. Konfirmasi.

Jangan melakukan refund penuh setelah semua nilai sudah dikembalikan melalui refund sebagian.

# 13. Giliran kerja, kas, dan absensi

## 13.1 Kas Masuk

Gunakan untuk dana tambahan di laci kas yang bukan penjualan, misalnya tambahan uang kecil.

1. Buka halaman shift.
2. Tekan **Kas Masuk**.
3. Isi nominal.
4. Isi alasan.
5. Simpan.

## 13.2 Kas Keluar

Gunakan **Kas Keluar** ketika uang benar-benar diambil dari laci kasir selama giliran kerja masih aktif. Contohnya adalah membayar pembelian gas, ongkos pengiriman, parkir, atau kebutuhan mendadak lainnya menggunakan uang tunai dari laci.

Owner, Admin, dan Manajer dapat mencatat pergerakan kas pada cabang yang menjadi tanggung jawabnya. Kasir hanya dapat mencatat Kas Keluar pada giliran kerja miliknya sendiri.

1. Buka halaman **Shift** pada aplikasi kasir.
2. Pastikan giliran kerja masih aktif.
3. Tekan **Kas Keluar**.
4. Masukkan jumlah uang yang diambil dari laci.
5. Pilih kategori Pengeluaran.
6. Isi alasan yang jelas, misalnya `Beli gas LPG - nota 024`.
7. Periksa kembali kategori, jumlah, dan keterangannya.
8. Tekan **Simpan Kas Keluar**.

Kas Keluar mengurangi jumlah kas yang seharusnya tersedia di laci saat giliran kerja ditutup. Sistem juga langsung membuat catatan Pengeluaran pada cabang, tanggal, kategori, nominal, dan keterangan yang sama.

> Pengguna hanya perlu mengisi formulir Kas Keluar satu kali. Jangan membuat Pengeluaran manual untuk transaksi yang sama karena sistem sudah membuatnya secara otomatis.

## 13.3 Menutup shift

1. Pastikan semua order selesai atau ditangani.
2. Hitung uang tunai fisik.
3. Buka **Tutup Kasir**.
4. Masukkan kas aktual.
5. Periksa kas sistem, selisih, pembayaran tunai, dan nontunai.
6. Isi catatan jika ada selisih.
7. Konfirmasi tutup shift.
8. Simpan/cetak rekap bila diperlukan.

## 13.4 Absensi

Menu **Absensi** mencatat kehadiran sesuai fungsi aplikasi. Pastikan staff melakukan proses dengan akun dan PIN sendiri agar laporan tidak tertukar.

<div class="no-page-break"></div>

# 14. Pengeluaran

Lokasi: **OUTLET → Keuangan → Pengeluaran**

Halaman ini menampilkan biaya usaha yang dibuat secara manual maupun otomatis. Pengeluaran otomatis berasal dari Kas Keluar dan diberi tanda **Kas Keluar Otomatis**.

## 14.1 Pengguna yang dapat mengelola pengeluaran

- **Owner** dapat menambah, mengubah, dan menghapus pengeluaran pada cabang yang dipilih.
- **Admin** dapat menambah, mengubah, dan menghapus pengeluaran pada cabangnya.
- **Manajer** dapat menambah dan mengubah pengeluaran pada cabangnya, tetapi tidak dapat menghapus.
- **Kasir** tidak memiliki akses ke halaman Pengeluaran pada Web Owner Panel. Pengeluaran yang dicatat Kasir melalui **Kas Keluar** tetap masuk secara otomatis.

## 14.2 Cara mencatat pengeluaran

1. Pilih cabang yang benar melalui pemilih cabang di bagian atas halaman.
2. Buka **Keuangan → Pengeluaran**.
3. Tekan **Tambah**.
4. Pilih tanggal pengeluaran. Tanggal tidak boleh berada di masa depan.
5. Pilih kategori yang paling sesuai.
6. Masukkan nominal yang lebih besar dari nol.
7. Isi keterangan yang mudah diperiksa, misalnya nama barang, nomor nota, atau tujuan pembayaran.
8. Periksa kembali cabang, tanggal, kategori, nominal, dan keterangan.
9. Tekan **Simpan**.

Contoh kategori:

- Bahan Baku.
- Operasional.
- Gaji.
- Peralatan.
- Pemasaran.
- Lain-lain.

## 14.3 Menentukan cara pencatatan

| Cara pembayaran | Tindakan pengguna | Hasil sistem |
|---|---|---|
| Dibayar menggunakan uang dari laci kasir | Isi **Kas Keluar** satu kali | Saldo laci berkurang dan Pengeluaran dibuat otomatis |
| Dibayar melalui transfer rekening perusahaan | Isi **Tambah Pengeluaran** | Pengeluaran masuk ke laporan tanpa mengubah saldo laci |
| Dibayar menggunakan kartu atau dompet digital perusahaan | Isi **Tambah Pengeluaran** | Pengeluaran masuk ke laporan tanpa mengubah saldo laci |

Contoh: kasir mengambil Rp100.000 dari laci untuk membeli gas. Kasir cukup mengisi **Kas Keluar Rp100.000**, memilih kategori Operasional, lalu mengisi keterangannya. Sistem mengurangi kas shift dan membuat Pengeluaran Rp100.000 secara bersamaan.

## 14.4 Laporan pengeluaran Kasir

Pengeluaran yang dibuat dari Kas Keluar masuk ke:

- **OUTLET → Keuangan → Pengeluaran**, dengan tanda **Kas Keluar Otomatis**.
- Ringkasan **Total Pengeluaran** pada Dashboard cabang.
- Rincian pengeluaran berdasarkan kategori.
- Laporan keuangan dan perhitungan laba bersih sesuai aturan kategori.
- Rekap kas shift sebagai Kas Keluar untuk menghitung Kas Seharusnya.

Catatan tersebut menggunakan cabang dari giliran kerja Kasir. Karena itu, pengeluaran tidak tercampur dengan cabang lain.

# 15. Laporan

## 15.1 Laporan Owner

Menu Owner:

- Dashboard semua cabang.
- Monitoring Cabang.
- Laporan Keuangan.
- Detail metode pembayaran.
- Performa outlet.
- Produk teratas.
- Penjualan per kategori.
- Penjualan per kasir.

Gunakan filter outlet dan periode sebelum membaca angka.

## 15.2 Laporan outlet

Menu laporan tersedia:

- Ringkasan Penjualan.
- Detail Penjualan.
- Departemen.
- Kategori.
- Extra.
- Pajak.
- Service Charge.
- Menu.
- Sub Extra.
- Tutup Kasir.
- Refund.
- Refund Sebagian.
- Void.

## 15.3 Menggunakan filter laporan

1. Pilih periode.
2. Pilih kasir atau outlet jika tersedia.
3. Tunggu data selesai dimuat.
4. Periksa kartu ringkasan.
5. Periksa tabel.
6. Ekspor CSV, Excel, atau PDF bila tombol tersedia.

Jika hasil kosong:

- Periksa cabang.
- Periksa periode.
- Pastikan transaksi berstatus sesuai laporan.
- Hapus filter pencarian.

## 15.4 Membaca Ringkasan Penjualan

Komponen dapat mencakup:

- Penjualan kotor.
- Pajak.
- Service charge.
- Total pendapatan.
- Diskon promo/voucher.
- Tukar poin.
- Refund atau pengembalian.
- Penjualan bersih.
- HPP.
- Laba kotor.
- Pengeluaran.
- Laba bersih.

Gunakan definisi yang sama setiap kali membandingkan cabang.

# 16. Pemantauan perangkat dan penggunaan tanpa internet

## 16.1 Monitoring Perangkat

Lokasi POS: **Pengaturan → Monitoring Perangkat**

Halaman ini membantu melihat:

- Status antrean transaksi offline.
- Transaksi yang ditolak server.
- Antrean cetak gagal.
- Opsi mencoba ulang.

## 16.2 Saat internet terputus

1. Jangan menutup paksa aplikasi.
2. Periksa indikator jaringan.
3. Lanjutkan hanya transaksi yang memang didukung antrean offline.
4. Jangan membuat transaksi yang sama di perangkat lain.
5. Setelah jaringan kembali, buka Monitoring Perangkat.
6. Pastikan antrean tersinkron.
7. Tangani transaksi ditolak satu per satu.

## 16.3 Dead-letter atau transaksi ditolak

Transaksi yang ditolak tidak terus menghambat transaksi lain. Operator dapat:

- Membaca penyebab.
- Memperbaiki kondisi terkait.
- Mencoba ulang.
- Menghubungi admin bila data tidak dapat diperbaiki dari POS.

Jangan membuang catatan transaksi ditolak sebelum memastikan transaksi memang tidak sah atau sudah dicatat dengan cara lain.

# 17. Catatan kesalahan sistem

Lokasi: **OWNER → Sistem → Log Error**

Gunakan log untuk melihat:

- Pesan error.
- Platform.
- Versi aplikasi.
- Role pengguna.
- Waktu kejadian.
- Stack trace teknis.

Saat melaporkan masalah, sertakan:

- Waktu kejadian.
- Cabang.
- Nama pengguna.
- Langkah sebelum error.
- Screenshot.
- Status jaringan.
- Printer/perangkat terkait.

Log lama memiliki kebijakan retensi agar tidak memenuhi database. Jangan menggunakan Log Error sebagai arsip bisnis.

# 18. Prosedur operasional standar harian

## 18.1 SOP buka outlet

- Nyalakan router dan periksa internet.
- Nyalakan printer dan periksa kertas.
- Login menggunakan Akun Perangkat cabang yang benar.
- Clock-in dengan PIN pribadi.
- Buka shift dengan modal awal.
- Tes cetak struk.
- Tes printer dapur/bar.
- Periksa menu habis dan status Tersedia.
- Periksa order online.
- Periksa stok kritis.

## 18.2 SOP saat operasional

- Pastikan meja sesuai order.
- Konfirmasi ekstra dan catatan.
- Jangan berbagi PIN.
- Tunggu hasil pembayaran.
- Tangani order gagal dari Monitoring Perangkat.
- Catat kas masuk/keluar beserta alasan.
- Gunakan Void/Refund sesuai status.
- Jangan menghapus data untuk menutupi kesalahan transaksi.

## 18.3 SOP tutup outlet

- Selesaikan order aktif.
- Sinkronkan antrean offline.
- Coba ulang cetak yang masih tertunda bila diperlukan.
- Hitung kas fisik.
- Tutup shift dan catat selisih.
- Periksa ringkasan penjualan.
- Catat pengeluaran.
- Lakukan stock opname sesuai jadwal.
- Matikan printer setelah seluruh tiket selesai.
- Logout jika perangkat tidak ditinggal di lokasi aman.

# 19. Penyelesaian masalah

## 19.1 Tidak bisa login web

- Periksa email dan password.
- Pastikan akun aktif.
- Pastikan akun memiliki akses web.
- Coba reset password melalui Owner jika diizinkan.
- Periksa tanggal dan waktu perangkat.

## 19.2 Nama staff tidak muncul saat clock-in

- Pastikan Akun Perangkat terhubung ke cabang yang benar.
- Pastikan staff ditetapkan pada cabang itu.
- Pastikan staff aktif.
- Muat ulang daftar atau login ulang perangkat.

## 19.3 PIN ditolak

- Pastikan empat digit benar.
- Periksa apakah akun terkunci sementara setelah percobaan gagal.
- Tunggu masa kunci berakhir.
- Minta Owner/Admin mengatur ulang PIN.

## 19.4 Menu tidak muncul di POS

- Pastikan cabang benar.
- Pastikan menu aktif dan Tersedia.
- Pastikan kategori aktif.
- Hapus filter kategori/pencarian.
- Muat ulang aplikasi.
- Periksa koneksi dan cache data.

## 19.5 Menu Unggulan tidak berada di atas

- Pastikan toggle Unggulan sudah disimpan.
- Pastikan aplikasi memakai versi terbaru.
- Muat ulang daftar menu.
- Periksa apakah pencarian/kategori menyembunyikan produk.

## 19.6 QR tidak bisa dibuka

- Pastikan meja aktif.
- Pastikan QR tidak rusak.
- Uji dari jaringan seluler.
- Buat ulang QR bila token tidak valid.
- Pastikan order online aktif dan berada dalam jam operasional.

## 19.7 Total pelanggan berbeda

- Periksa pajak inclusive/exclusive.
- Periksa service charge.
- Periksa pembulatan.
- Periksa promo dan loyalty.
- Pastikan E-Menu dan POS memakai konfigurasi outlet yang sama.

## 19.8 Pembayaran terlihat gagal

- Jangan langsung mengulang.
- Periksa Daftar Order.
- Periksa riwayat pembayaran.
- Periksa Monitoring Perangkat.
- Untuk nontunai, periksa aplikasi penyedia pembayaran.
- Ulang hanya setelah yakin transaksi pertama tidak tercatat.

## 19.9 Data laporan kosong

- Periksa rentang tanggal.
- Periksa cabang.
- Periksa status order.
- Periksa filter kasir atau pencarian.
- Pastikan transaksi sudah tersinkron.

## 19.10 Stok tidak sesuai

- Periksa resep.
- Periksa satuan.
- Periksa transaksi stok manual.
- Periksa waste.
- Periksa order void/refund.
- Lakukan stock opname dan catat penyebab selisih.

# 20. Keamanan dan pengelolaan data

## 20.1 Prinsip akses minimum

Berikan role sesuai kebutuhan. Jangan memberikan akses Owner kepada staff yang hanya perlu melihat laporan.

## 20.2 Tindakan sensitif

Tindakan berikut harus diawasi:

- Refund.
- Refund sebagian.
- Void.
- Reset password.
- Perubahan PIN.
- Penghapusan staff.
- Penghapusan cabang.
- Finalisasi stock opname.
- Perubahan pajak.

## 20.3 Data pelanggan

- Gunakan hanya untuk operasional yang sah.
- Batasi ekspor.
- Jangan membagikan nomor telepon.
- Simpan file laporan di lokasi aman.
- Hapus file ekspor yang tidak lagi diperlukan sesuai kebijakan bisnis.

# 21. Daftar pemeriksaan penerimaan sistem

Gunakan daftar ini sebelum outlet dinyatakan siap produksi.

## 21.1 Akun dan akses

- [ ] Owner dapat login.
- [ ] Admin/Manajer melihat menu sesuai role.
- [ ] Akun Perangkat terhubung ke cabang benar.
- [ ] Kasir dapat clock-in.
- [ ] PIN unik dan terdokumentasi aman.
- [ ] Akses Refund sesuai kebijakan.

## 21.2 Produk

- [ ] Departemen dan kategori benar.
- [ ] Menu dan harga benar.
- [ ] Menu Unggulan tampil di atas dan memiliki badge.
- [ ] Menu habis tidak dapat dipilih.
- [ ] Ekstra dan harga tambahan benar.
- [ ] Paket memiliki komponen benar.

## 21.3 Transaksi

- [ ] Dine In meminta meja.
- [ ] Takeaway tidak meminta meja.
- [ ] Tahan Pesanan dapat dilanjutkan.
- [ ] Tambah Pesanan bekerja pada order aktif.
- [ ] Pembayaran tunai dan nontunai tercatat.
- [ ] Split payment dapat difinalisasi.
- [ ] Void dan refund meminta persetujuan.
- [ ] Pindah meja dan gabung tagihan berhasil.

## 21.4 Printer

- [ ] Struk tercetak.
- [ ] Tiket dapur masuk ke stasiun benar.
- [ ] Tiket bar tidak masuk ke dapur.
- [ ] Auto-print sesuai pengaturan.
- [ ] Cetak ulang manual bekerja.
- [ ] Tidak ada printer duplikat.

## 21.5 Laporan dan stok

- [ ] Transaksi uji muncul di laporan.
- [ ] Pajak dan biaya layanan dihitung dengan benar.
- [ ] Giliran kerja kasir dapat ditutup.
- [ ] Stok berubah sesuai resep.
- [ ] Pengembalian dana dan pembatalan muncul pada laporan terkait.
- [ ] Pengeluaran memengaruhi laporan keuangan.

<div class="no-page-break"></div>

# 22. Glosarium

| Istilah | Arti |
|---|---|
| **Outlet atau Cabang** | Lokasi usaha yang memiliki pengaturan dan data operasional sendiri |
| **Akun Perangkat** | Akun untuk masuk ke tablet atau perangkat kasir. Akun ini bukan akun staf |
| **Clock-in atau Catat Waktu Masuk** | Proses ketika staf memilih namanya dan memasukkan nomor identifikasi pribadi sebelum mulai bekerja |
| **Shift atau Giliran Kerja** | Sesi kerja kasir yang dimulai dengan pencatatan modal awal dan diakhiri dengan pemeriksaan kas |
| **Dine In atau Makan di Tempat** | Pesanan yang dimakan di lokasi usaha dan biasanya terhubung dengan nomor meja |
| **Takeaway atau Bawa Pulang** | Pesanan yang dibawa pulang oleh pelanggan |
| **Self-Order atau Pesan Mandiri** | Pesanan yang dibuat sendiri oleh pelanggan melalui kode QR |
| **Unggulan** | Menu prioritas yang tampil lebih dahulu dan memiliki tanda bintang |
| **Tags atau Penanda** | Informasi tambahan untuk mengelompokkan menu. Penanda belum menjadi penyaring bagi pelanggan |
| **Stasiun Cetak** | Tujuan pencetakan tiket, misalnya Dapur atau Bar. Stasiun cetak bukan printer fisik |
| **Printer Fisik** | Perangkat pencetak yang terhubung melalui Bluetooth atau jaringan lokal |
| **Void atau Pembatalan** | Pembatalan pesanan sesuai dengan status pesanan dan aturan pencatatan sistem |
| **Refund atau Pengembalian Dana** | Pengembalian pembayaran untuk transaksi yang sudah dibayar |
| **Refund Sebagian** | Pengembalian dana hanya untuk sebagian barang atau sebagian nilai transaksi |
| **Stock Opname atau Pemeriksaan Stok** | Proses mencocokkan jumlah stok di dalam sistem dengan jumlah barang yang tersedia secara fisik |
| **HPP atau Harga Pokok Penjualan** | Perkiraan biaya produk berdasarkan harga bahan yang digunakan |
| **Dead-letter atau Antrean Gagal** | Transaksi yang tidak dapat diproses otomatis dan harus diperiksa oleh pengguna yang berwenang |

<div class="no-page-break"></div>

# 23. Informasi dukungan

Saat meminta bantuan, siapkan:

- Nama outlet.
- Nama dan peran pengguna.
- Tanggal serta waktu kejadian.
- Nomor pesanan jika ada.
- Gambar layar atau video singkat.
- Jenis perangkat dan versi aplikasi.
- Status internet.
- Nama printer dan tipe koneksi.

**Kontak dukungan:** isi sesuai kontak resmi penyedia Time420s.
**Jam dukungan:** isi sesuai perjanjian layanan.

---

Dokumen ini adalah panduan operasional. Kebijakan bisnis, perpajakan, perlindungan data, dan prosedur pengembalian dana tetap mengikuti keputusan serta kewajiban hukum pemilik usaha.

# Riwayat Perubahan (Changelog)

Format mengikuti [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Ditambahkan
- Program Loyalty member dengan tier Bronze/Silver/Gold/Platinum
- Laporan audit log pesanan (riwayat perubahan status semua order)
- Laporan stok harian
- Kartu jam sibuk (peak hours) di dashboard admin
- Halaman manajemen pengeluaran (Expense Manager)
- Halaman daftar pesanan (Order List) dengan filter status
- Halaman ringkasan shift kasir (Shift List)
- Halaman laporan stok (Stock Report)
- View database: jam sibuk, penjualan per kategori, stok harian

---

## [1.0.0] — 2026-05-27

### Ditambahkan

#### Fitur Inti
- **Inventori Resep** — Hubungkan item menu ke bahan baku; stok otomatis berkurang saat pesanan masuk dapur (status `preparing`)
- **Rollback Stok** — Stok otomatis dikembalikan saat pesanan dibatalkan atau di-void
- Laporan analitik lengkap dengan grafik (penjualan harian, item terlaris, metode pembayaran, laba rugi)
- Export laporan ke CSV, Excel, dan PDF
- Splash screen animasi di Customer E-Menu
- Support multiple konfigurasi pajak per outlet

#### Manajemen Outlet
- Dashboard admin dengan ringkasan pendapatan hari ini, pesanan aktif, stok kritis
- Dashboard owner dengan monitoring semua cabang
- Pengaturan struk (header, footer, logo)
- Pengaturan pajak & service charge per outlet
- Manajemen metode pembayaran yang dapat diaktifkan/dinonaktifkan

#### Menu & Katalog
- Manajemen departemen dengan assignment kategori
- Manajemen kategori dengan ikon dan urutan drag-and-drop
- Manajemen item menu (nama, harga, foto, deskripsi, tag, varian)
- Upload foto menu langsung dari browser
- Manajemen ekstra/topping dengan harga dan pilihan

#### Meja & QR
- Manajemen meja dengan area, kapasitas, status
- Generate QR code unik per meja (client-side, via library `qrcode`)
- Download QR code untuk dicetak

#### Stok & Inventori
- Manajemen bahan baku (nama, satuan, harga, stok minimum)
- Transaksi stok manual: pembelian, penyesuaian, pembuangan, retur
- View `v_low_stock` untuk monitoring stok kritis

#### Promo & Voucher
- Promo dengan tipe: persentase, nominal, bundling, BOGO
- Generate kode voucher dengan batas penggunaan
- Validasi tanggal berlaku dan minimum order

#### Pesanan & Pembayaran
- Customer self-order via QR code (E-Menu berbasis web)
- Alur status pesanan: draft → confirmed → preparing → ready → served → paid → cancelled/void
- Realtime update pesanan menggunakan Supabase Realtime
- Pembayaran multi-metode (cash, QRIS, debit, kredit, e-wallet, transfer)
- Auto-generate nomor pesanan berformat `ORD-YYYYMMDD-XXXX`

#### Sistem & Keamanan
- Row Level Security (RLS) penuh di seluruh tabel
- Isolasi data antar outlet
- Autentikasi Supabase dengan JWT
- Role-based access control (owner / admin / manajer / kasir)
- Auto-create profil saat user baru mendaftar (via trigger database)
- Auto-update `updated_at` di semua tabel via trigger

---

### Diperbaiki

- Resolve TypeScript build errors untuk deployment Cloudflare Pages
- Ganti dynamic import `xlsx` dengan export HTML murni untuk menghindari error Vite
- Lazy-load `jspdf` dan `xlsx` untuk memperbaiki error dynamic import
- Install dependency `react-is` yang hilang (dibutuhkan oleh `recharts`)
- Generate QR code dijalankan di sisi klien menggunakan library `qrcode` (sebelumnya bergantung pada server)
- Perbaiki infinite loop di `MenuItemForm` pada efek ekstra
- Perbaiki referensi `MenuExtra.price` setelah refactor tipe ke `menu_extra_options`
- Perbaiki kebijakan RLS anonymous untuk Customer E-Menu
- Perbaiki tampilan kartu Customer E-Menu untuk layar mobile
- Tambah fallback graceful saat tabel database belum tersedia
- Update `MENU_BASE_URL` ke domain Cloudflare Pages yang benar

---

### Diubah

- Terjemahkan seluruh teks UI dashboard ke Bahasa Indonesia
- Format input harga menggunakan pemisah ribuan (titik) di semua form
- Desain ulang `ExtraManager`, `TaxSettings`, `ReceiptSettings` dalam seksi Pembayaran yang terintegrasi
- Desain ulang `DepartmentManager` dengan layout tabel dan form assignment kategori
- Hapus titik warna dari baris tabel `CategoryManager` dan `DepartmentManager`
- Rename "Produk" menjadi "Menu" di sidebar navigasi

---

## [0.1.0] — 2026-04 (Beta Internal)

### Ditambahkan
- Inisialisasi proyek dengan Vite + React + TypeScript
- Setup Supabase client dan autentikasi
- Routing berbasis role (owner / admin)
- Skeleton komponen UI menggunakan Radix UI + Tailwind CSS
- Skema database awal (tabel, views, RLS)
- Prototype Customer E-Menu (vanilla HTML/CSS/JS)
- Seksi Pembayaran: metode pembayaran, struk, biaya, pajak
- Seksi Menu: kategori, departemen, item, ekstra
- Deploy ke Cloudflare Pages

---

*Lihat commit log untuk detail perubahan per commit.*

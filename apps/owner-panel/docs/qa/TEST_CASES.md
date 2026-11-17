# Test Cases — Owner Panel

**Versi:** 1.0
**Tanggal:** 2026-05-28

Format ID: `TC-<MODUL>-<NN>`. Severity: BLOCKER / CRITICAL / HIGH / MEDIUM / LOW.

---

## 1. Auth (`/login`)

| ID | Title | Pre-condition | Steps | Expected | Severity |
|---|---|---|---|---|---|
| TC-AUTH-01 | Login dengan kredensial valid | User aktif di Supabase Auth | 1. Buka `/login` 2. Isi email + password 3. Klik "Masuk" | Redirect ke `/dashboard` (owner) atau `/admin/dashboard` (admin) dalam < 5 detik | CRITICAL |
| TC-AUTH-02 | Login dengan password salah | - | 1. Isi email valid + password salah 2. Submit | Toast/inline error muncul, tidak redirect | HIGH |
| TC-AUTH-03 | Login dengan email belum terdaftar | - | 1. Isi email random + password apapun 2. Submit | Error message "Invalid login credentials" | HIGH |
| TC-AUTH-04 | Field email & password wajib | - | 1. Submit dengan field kosong | Validation error, submit tidak terkirim | MEDIUM |
| TC-AUTH-05 | Email format invalid | - | 1. Isi `notanemail` 2. Submit | Validation error | MEDIUM |
| TC-AUTH-06 | Auto-redirect jika sudah login | Session aktif | 1. Buka `/login` saat sudah login | Auto redirect ke dashboard | MEDIUM |
| TC-AUTH-07 | Logout button | Sudah login | 1. Klik "Keluar" di sidebar | Redirect ke `/login`, session terhapus | HIGH |
| TC-AUTH-08 | Akses route protected tanpa login | Logged out | 1. Buka langsung `/admin/dashboard` | Redirect ke `/login` | CRITICAL |
| TC-AUTH-09 | Admin tidak bisa akses route Owner | Login as admin | 1. Buka `/owner/dashboard` | Redirect / 403 / disembunyikan dari sidebar | HIGH |
| TC-AUTH-10 | Session expires | Token expired | 1. Tunggu sampai session expired 2. Click sidebar nav | Redirect ke `/login` | HIGH |

## 2. Dashboard

### 2.1 Owner Dashboard (`/owner/dashboard`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-DASH-O-01 | Page load | Login as owner | Dashboard render dalam < 5 detik | HIGH |
| TC-DASH-O-02 | Stat cards menampilkan angka | Buka dashboard | Total revenue, transaksi, dll tidak Rp0 jika ada data | CRITICAL |
| TC-DASH-O-03 | Outlet selector | Klik outlet selector | Dropdown muncul, klik outlet lain → data berubah | HIGH |
| TC-DASH-O-04 | Payment widget (broken — BUG-LAP-API-002) | Lihat widget pembayaran | Saat ini kosong, harusnya tampil chart | HIGH |
| TC-DASH-O-05 | Top kasir leaderboard (broken — BUG-LAP-API-003) | Lihat widget kasir | Saat ini kosong, harusnya tampil top kasir | HIGH |
| TC-DASH-O-06 | Low stock alert | Buka dashboard saat ada bahan stock < min | Alert muncul dengan list bahan | MEDIUM |
| TC-DASH-O-07 | Mobile responsive | Resize ke 375px | Stat cards 2 kolom, tidak overflow | HIGH |

### 2.2 Admin Dashboard (`/admin/dashboard`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-DASH-A-01 | Page load | Login as admin | Dashboard render dalam < 5 detik | HIGH |
| TC-DASH-A-02 | Active orders realtime | Buka dashboard, ada order baru dari mobile | Order baru muncul tanpa refresh < 3 detik | HIGH |
| TC-DASH-A-03 | Outlet auto-selected | Login as admin | Outlet user otomatis terpilih | HIGH |
| TC-DASH-A-04 | Tables widget | Buka dashboard | Menampilkan jumlah meja kosong / terpakai | MEDIUM |

## 3. Produk

### 3.1 Departments (`/admin/departments`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-DEPT-01 | List departemen | Buka halaman | Tabel muncul dengan kolom: nama, warna, status | HIGH |
| TC-DEPT-02 | Tambah departemen | Klik "+ Departemen", isi nama + warna, simpan | Departemen baru muncul di list | HIGH |
| TC-DEPT-03 | Edit departemen | Klik edit pada row, ubah nama, simpan | Nama updated di list | HIGH |
| TC-DEPT-04 | Toggle status aktif/non-aktif | Klik toggle | Status berubah, badge update | MEDIUM |
| TC-DEPT-05 | Hapus departemen | Klik delete, konfirmasi | Departemen hilang dari list | MEDIUM |
| TC-DEPT-06 | Validasi nama wajib | Tambah tanpa nama | Error validation | MEDIUM |
| TC-DEPT-07 | Sort/drag-and-drop | Drag row | Urutan tersimpan di backend | LOW |

### 3.2 Categories (`/admin/categories`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-CAT-01 | List kategori dengan departemen | Buka halaman | Tabel muncul, kolom: nama, departemen, status | HIGH |
| TC-CAT-02 | Tambah kategori | Pilih departemen, isi nama, simpan | Kategori baru muncul | HIGH |
| TC-CAT-03 | Edit kategori | Klik edit, ubah departemen | Departemen update | HIGH |
| TC-CAT-04 | Hapus kategori dengan menu di dalamnya | Hapus kategori yg ada menu | Error / cascade behavior terdefinisi | HIGH |

### 3.3 Menu (`/admin/menu`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-MENU-01 | List menu | Buka halaman | Tabel/grid dengan: nama, harga, kategori, stok, status | CRITICAL |
| TC-MENU-02 | Tambah menu baru | Isi semua field, upload foto, simpan | Menu muncul di list + di POS mobile | CRITICAL |
| TC-MENU-03 | Edit harga menu | Klik edit, ubah harga, simpan | Harga update di list, dashboard | HIGH |
| TC-MENU-04 | Upload foto menu | Browse → JPG/PNG < 2MB | Upload success, preview muncul | HIGH |
| TC-MENU-05 | Upload foto > 2MB | Upload file besar | Error "file too large" | MEDIUM |
| TC-MENU-06 | Toggle menu out-of-stock | Klik toggle | Mobile POS tidak bisa pesan | HIGH |
| TC-MENU-07 | Hapus menu | Klik delete | Menu hilang dari list, tidak muncul di POS | HIGH |
| TC-MENU-08 | Filter by kategori | Pilih filter kategori | List ter-filter | MEDIUM |
| TC-MENU-09 | Search menu by nama | Ketik di search | List ter-filter | MEDIUM |
| TC-MENU-10 | Menu dengan resep bahan baku | Buka menu, tambah resep | Stok bahan berkurang saat order paid | HIGH |

### 3.4 Extras (`/admin/extras`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-EXTRA-01 | List extras | Buka halaman | Tabel muncul, kolom: nama, tipe, seleksi, opsi | HIGH |
| TC-EXTRA-02 | Tambah extra dengan opsi | Isi nama, tambah opsi + harga | Extra + opsi tersimpan | HIGH |
| TC-EXTRA-03 | Edit harga opsi | Klik edit opsi, ubah harga | Harga update | MEDIUM |

## 4. Laporan

### 4.1 Ringkasan Penjualan (`/admin/reports`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-RPT-01 | Page load | Buka halaman | Stat cards + tabel render < 5 detik | CRITICAL |
| TC-RPT-02 | Stat cards: Total Penjualan, Transaksi, Pembersih, Pembayaran, Piutang | Buka halaman | Semua 5 stat menampilkan nilai numerik (bukan NaN/undefined) | CRITICAL |
| TC-RPT-03 | Tabel transaksi: 8 kolom | Buka halaman | Kolom: No Transaksi, Waktu Order, Waktu Bayar, Jenis Order, Total, Pembayaran, Bayar, Order | HIGH |
| TC-RPT-04 | Date range default 30 hari | Buka halaman | Date picker menampilkan 30 hari terakhir | MEDIUM |
| TC-RPT-05 | Search by no transaksi / nama | Ketik di search | Tabel ter-filter realtime | MEDIUM |
| TC-RPT-06 | Date picker — pilih custom range | Klik picker, pilih tanggal, "Proses" | Tabel + stat update | HIGH |
| TC-RPT-07 | Date picker — preset "Hari Ini" | Klik preset | Range = hari ini | MEDIUM |
| TC-RPT-08 | Date picker — preset "Bulan Lalu" | Klik preset | Range = bulan lalu, multi-month data terambil | HIGH |
| TC-RPT-09 | Export CSV | Klik Export → CSV | File `.csv` ter-download, header benar, data lengkap | HIGH |
| TC-RPT-10 | Export Excel | Klik Export → Excel | File `.xls` ter-download, header oranye, kolom rapi | HIGH |
| TC-RPT-11 | Export PDF | Klik Export → PDF | File `.pdf` ter-download, layout rapi | MEDIUM |
| TC-RPT-12 | Kolom Bayar/Order = nama kasir | Buka tabel | Kolom isi nama kasir dari `staff_map`, bukan UUID | HIGH |
| TC-RPT-13 | Kolom Waktu Bayar — order belum bayar | Lihat order draft/confirmed | Kolom = "—" | MEDIUM |
| TC-RPT-14 | Kosong state | Range tanpa data | Tabel menampilkan "Tidak ada transaksi" | MEDIUM |
| TC-RPT-15 | Mobile responsive (375px) | Resize | Stat cards 2 kolom, tabel horizontal scroll | HIGH |

### 4.2 Sales Breakdown (`/admin/sales-breakdown/:tab`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-SBR-01 | Departemen tab | Klik "Departemen" | URL → `/departemen`, stat + tabel render | HIGH |
| TC-SBR-02 | Kategori tab — multi-month range (regresi BUG-LAP-003) | Pilih range 60 hari, lihat tab Kategori | Semua bulan ter-aggregate, tidak hanya 1 bulan | HIGH |
| TC-SBR-03 | Kategori tab — total_orders ada (regresi BUG-LAP-005) | Buka tab | Tidak crash, kolom Orders menampilkan angka | HIGH |
| TC-SBR-04 | Menu tab | Klik "Menu" | Tabel muncul dengan nama menu, qty, revenue | HIGH |
| TC-SBR-05 | Extra tab | Klik "Extra" | Tabel extras + opsi | MEDIUM |
| TC-SBR-06 | Pajak tab | Klik "Pajak & Biaya" | 3 stat cards (Transaksi, Penjualan, Service Charge) | HIGH |
| TC-SBR-07 | Pajak tab — Hari/Bulan/Tahun toggle | Pilih "Bulan" | Tabel ter-group by bulan | MEDIUM |
| TC-SBR-08 | Currency tidak Rp0 (regresi BUG-LAP-001) | Buka semua tab | Semua nilai currency menampilkan angka benar | CRITICAL |
| TC-SBR-09 | Export per tab | Export CSV/Excel/PDF di setiap tab | File berisi data tab terpilih | HIGH |
| TC-SBR-10 | Sidebar navigation | Klik sub-item di sidebar | URL berubah, tab aktif | MEDIUM |
| TC-SBR-11 | Redirect `/sales-breakdown` → `/departemen` | Buka URL parent | Auto redirect | LOW |

## 5. Pesanan

### 5.1 Daftar Pesanan (`/admin/orders`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-ORD-01 | List orders | Buka halaman | Tabel orders dengan status, total, kasir | HIGH |
| TC-ORD-02 | Realtime new order | Buka halaman, mobile buat order baru | Order baru muncul tanpa refresh | HIGH |
| TC-ORD-03 | Filter by status | Pilih filter "Paid" | List hanya status paid | MEDIUM |
| TC-ORD-04 | Detail order | Klik row | Modal/page detail muncul dengan items | HIGH |
| TC-ORD-05 | Void order | Klik void, isi reason | Status berubah `void`, reason tersimpan | HIGH |
| TC-ORD-06 | Audit log | Buka detail | Log perubahan status muncul | MEDIUM |

### 5.2 Shift Kasir (`/admin/shifts`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-SHIFT-01 | List shifts | Buka halaman | Tabel shift dengan kasir, waktu, cash | HIGH |
| TC-SHIFT-02 | Open shift | Klik "Buka Shift", isi cash awal | Shift terbuka | HIGH |
| TC-SHIFT-03 | Close shift | Klik close pada shift open, isi cash akhir | Shift tertutup, hitung selisih | HIGH |
| TC-SHIFT-04 | Date filter | Pilih tanggal | List ter-filter | MEDIUM |

## 6. Inventori

### 6.1 Stok Bahan Baku (`/admin/stock`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-STK-01 | List ingredients | Buka halaman | Tabel dengan: nama, unit, stock, min, cost | HIGH |
| TC-STK-02 | Tambah bahan baku | Isi form, simpan | Bahan baru muncul | HIGH |
| TC-STK-03 | Stock in (penerimaan) | Klik "Stock In", isi qty + harga | Stock bertambah, transaction log | HIGH |
| TC-STK-04 | Stock out (pemakaian manual) | Klik "Stock Out", isi qty | Stock berkurang | HIGH |
| TC-STK-05 | Stock adjustment | Klik adjust, isi alasan | Stock ter-set ke nilai baru | MEDIUM |
| TC-STK-06 | Low stock warning | Stock < min | Row di-highlight merah | MEDIUM |
| TC-STK-07 | Filter aktif/non-aktif | Toggle filter | List ter-filter | LOW |

### 6.2 Laporan Stok (`/admin/stock-report`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-STKR-01 | List transaksi stok | Buka halaman | Tabel log mutasi stok | HIGH |
| TC-STKR-02 | Filter by tipe | Pilih filter "In" / "Out" | List ter-filter | MEDIUM |

## 7. Keuangan

### 7.1 Pengeluaran (`/admin/expenses`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-EXP-01 | List pengeluaran | Buka halaman | Tabel pengeluaran per bulan | HIGH |
| TC-EXP-02 | Tambah pengeluaran | Isi kategori, nominal, deskripsi | Tersimpan, masuk laporan P&L | HIGH |
| TC-EXP-03 | Upload bukti | Browse file < 2MB | Upload success | MEDIUM |
| TC-EXP-04 | Hapus pengeluaran | Klik delete | Hilang dari list | MEDIUM |

### 7.2 Laporan Keuangan (`/owner/finance`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-FIN-01 | P&L statement | Pilih bulan | Gross revenue, HPP, gross profit, expenses, net profit | HIGH |
| TC-FIN-02 | Gross margin & net margin | Lihat sidebar metrics | Persentase margin valid | MEDIUM |

## 8. Operasional

### 8.1 Tables (`/admin/tables`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-TBL-01 | List meja | Buka halaman | Tabel meja per area | HIGH |
| TC-TBL-02 | Tambah meja | Isi nomor, area, kapasitas | Meja baru muncul | HIGH |
| TC-TBL-03 | Status meja realtime | Order masuk → meja terpakai | Status berubah | MEDIUM |

### 8.2 QR Code (`/admin/qr-codes`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-QR-01 | Generate QR per meja | Buka halaman | QR muncul untuk semua meja | HIGH |
| TC-QR-02 | Download QR | Klik download | PNG ter-download | MEDIUM |
| TC-QR-03 | Print semua QR | Klik print all | Print preview dengan semua QR | MEDIUM |
| TC-QR-04 | Scan QR di mobile | Scan dengan customer app | Buka halaman menu meja tersebut | HIGH |

## 9. Promosi & Loyalty

### 9.1 Promos (`/admin/promos`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-PRM-01 | List promo aktif | Buka halaman | Tabel promo dengan periode, diskon | HIGH |
| TC-PRM-02 | Buat promo baru | Isi kode, diskon, periode | Tersimpan, bisa dipakai di POS | HIGH |
| TC-PRM-03 | Promo expired | Tanggal sudah lewat | Status `expired`, tidak bisa dipakai | MEDIUM |
| TC-PRM-04 | Validasi tanggal mulai < akhir | Isi start > end | Validation error | MEDIUM |

### 9.2 Loyalty (`/admin/loyalty`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-LYL-01 | List member | Buka halaman | Tabel member dengan poin | MEDIUM |
| TC-LYL-02 | Adjust poin manual | Edit member, ubah poin | Poin update | MEDIUM |

## 10. Pembayaran & Pajak

### 10.1 Payment Methods (`/admin/payments`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-PAY-01 | List metode pembayaran | Buka halaman | List: Tunai, QRIS, Debit, dll | HIGH |
| TC-PAY-02 | Toggle aktif/non-aktif | Klik toggle | Mobile POS tidak menampilkan metode non-aktif | HIGH |

### 10.2 Tax Settings (`/admin/taxes`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-TAX-01 | Set persentase pajak | Edit field, simpan | Pajak otomatis diterapkan ke order baru | HIGH |
| TC-TAX-02 | Set service charge | Edit field, simpan | Service charge otomatis diterapkan | HIGH |
| TC-TAX-03 | Pilih order type kena pajak | Centang dine-in only | Takeaway tidak kena pajak | HIGH |

### 10.3 Receipt (`/admin/receipt`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-RCP-01 | Setting struk | Edit header, footer, simpan | Mobile POS print sesuai setting | HIGH |
| TC-RCP-02 | Toggle tampilkan logo | Centang | Logo muncul di struk | MEDIUM |

## 11. SDM (`/admin/staff` & `/owner/staff`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-STAFF-01 | List staff | Buka halaman | Tabel staff dengan role, outlet | HIGH |
| TC-STAFF-02 | Tambah staff baru | Isi nama, email, password, role | Staff baru bisa login | HIGH |
| TC-STAFF-03 | Edit role staff | Ubah role admin → kasir | Role update | HIGH |
| TC-STAFF-04 | Hapus staff (owner only) | Owner panel: klik delete + confirm | Staff terhapus dari auth.users | HIGH |
| TC-STAFF-05 | Filter by outlet (owner) | Owner pilih outlet | List ter-filter | MEDIUM |
| TC-STAFF-06 | Validasi email unik | Tambah staff dengan email existing | Error duplikasi | MEDIUM |
| TC-STAFF-07 | Validasi password min 6 chars | Isi password pendek | Validation error | MEDIUM |

## 12. Settings (`/admin/settings`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-SET-01 | Edit info outlet | Ubah nama, alamat | Tersimpan | HIGH |
| TC-SET-02 | Upload logo outlet | Browse PNG/JPG | Upload success, terlihat di struk | MEDIUM |
| TC-SET-03 | Set jam operasional | Edit jam buka/tutup | Tersimpan | MEDIUM |

## 13. Branch Monitoring (Owner — `/owner/branches`)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-BR-01 | List semua outlet | Owner buka halaman | Tabel outlet dengan revenue today | HIGH |
| TC-BR-02 | Klik outlet → detail | Klik row | Drilldown ke dashboard outlet | MEDIUM |

## 14. Cross-Cutting

### 14.1 Performance

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-PERF-01 | First Contentful Paint | Buka halaman cold | FCP < 2 detik di koneksi 4G | HIGH |
| TC-PERF-02 | Data fetch dashboard | Buka dashboard | Data ter-load < 5 detik | HIGH |
| TC-PERF-03 | Tabel 1000+ rows | Filter date range besar | Tidak freeze browser | MEDIUM |
| TC-PERF-04 | Export 1000+ rows | Export Excel | Selesai < 10 detik tanpa crash | MEDIUM |

### 14.2 Security

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-SEC-01 | RLS — anon role | Query view tanpa JWT | Return `[]`, tidak bocor data | CRITICAL |
| TC-SEC-02 | RLS — admin cross-outlet | Login admin outlet A, modify query ke outlet B | Tidak bisa baca data outlet B | CRITICAL |
| TC-SEC-03 | XSS di input field | Isi `<script>alert(1)</script>` di nama menu | Escaped, tidak execute | HIGH |
| TC-SEC-04 | Source map tidak ter-deploy | View DevTools Sources di production | Tidak ada .map file | HIGH |
| TC-SEC-05 | Chunk names obscured | View Sources panel | Nama file hash-only, bukan "Dashboard.js" | MEDIUM |
| TC-SEC-06 | CSV injection sanitization | Export CSV dengan cell mulai `=`, `+`, `@` | Cell di-prefix `'` | MEDIUM |

### 14.3 Mobile Responsive (375px Android Chrome)

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-MOB-01 | Sidebar collapse | Buka di mobile | Sidebar hidden, hamburger button | HIGH |
| TC-MOB-02 | Stat cards 2 kolom | Buka dashboard | Tidak overflow horizontal | HIGH |
| TC-MOB-03 | Tabel scroll horizontal | Buka tabel besar | Bisa scroll, tidak crash | HIGH |
| TC-MOB-04 | Date picker popup | Klik picker | Popup max-width clamp ke viewport | HIGH |
| TC-MOB-05 | Form input tidak overflow | Isi field panjang | Tidak keluar dari card | MEDIUM |

### 14.4 Browser Compatibility

| ID | Title | Browser | Severity |
|---|---|---|---|
| TC-BR-01 | Chrome desktop latest | Chrome 120+ | HIGH |
| TC-BR-02 | Safari macOS latest | Safari 17+ | HIGH |
| TC-BR-03 | Firefox latest | Firefox 120+ | MEDIUM |
| TC-BR-04 | Edge latest | Edge 120+ | MEDIUM |
| TC-BR-05 | Mobile Chrome Android | Chrome Android | HIGH |
| TC-BR-06 | Mobile Safari iOS | Safari iOS | MEDIUM |

### 14.5 Error Handling

| ID | Title | Steps | Expected | Severity |
|---|---|---|---|---|
| TC-ERR-01 | Network offline | Disable network, klik action | Error toast, tidak crash | HIGH |
| TC-ERR-02 | Supabase 500 | Mock 500 response | Error UI graceful | HIGH |
| TC-ERR-03 | Empty state | Halaman tanpa data | Pesan "Tidak ada data" + ikon | MEDIUM |
| TC-ERR-04 | 404 page | Buka URL random | Halaman 404 atau redirect | MEDIUM |

---

## Status Summary

**Total test cases:** ~130
**Coverage by priority:**
- CRITICAL: 12
- HIGH: 60
- MEDIUM: 50
- LOW: 8

**Untuk eksekusi:** lihat [REGRESSION_CHECKLIST.md](./REGRESSION_CHECKLIST.md) untuk subset wajib pre-release dan [AUTOMATION_GUIDE.md](./AUTOMATION_GUIDE.md) untuk yang ter-otomasi.

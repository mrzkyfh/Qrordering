# Test Cases — Owner Panel
**Versi:** 1.0 | **Tanggal:** 2026-05-27

Legend: ✅ Pass | ❌ Fail | ⚠️ Partial | 🔲 Not Tested

---

## TC-001 — Autentikasi & Login

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-001-01 | Login valid — owner | Input email+password owner → klik Masuk | Redirect ke /owner/dashboard | P0 |
| TC-001-02 | Login valid — admin | Input email+password admin → klik Masuk | Redirect ke /admin/dashboard | P0 |
| TC-001-03 | Login email salah | Input email tidak terdaftar | Toast "Email atau password salah" | P0 |
| TC-001-04 | Login password salah | Input password salah | Toast "Email atau password salah" | P0 |
| TC-001-05 | Login field kosong | Klik Masuk tanpa input | Validasi inline muncul | P0 |
| TC-001-06 | Login email format salah | Input "bukanEmail" | Validasi format email | P0 |
| TC-001-07 | Login password < 8 char | Input password "abc" | Validasi min 8 karakter | P0 |
| TC-001-08 | Show/hide password | Klik ikon mata | Password terlihat/tersembunyi | P1 |
| TC-001-09 | Loading state | Klik Masuk saat proses | Tombol disabled, teks "Memproses..." | P1 |
| TC-001-10 | Auto-redirect jika sudah login | Buka /login saat sudah auth | Redirect ke dashboard | P1 |
| TC-001-11 | Logout | Klik logout dari header | Session dihapus, redirect /login | P0 |
| TC-001-12 | Akses halaman tanpa login | Buka /admin/menu tanpa login | Redirect ke /login | P0 |

---

## TC-002 — Protected Route (Role-Based Access Control)

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-002-01 | Kasir akses /admin/menu | Login kasir, buka URL manual | Halaman 403 / redirect | P0 |
| TC-002-02 | Admin akses /owner/dashboard | Login admin, buka URL manual | Halaman 403 | P0 |
| TC-002-03 | Owner akses /admin/menu | Login owner, navigasi ke menu | Halaman tampil normal | P0 |
| TC-002-04 | Owner akses /owner/branches | Login owner | Halaman tampil normal | P0 |
| TC-002-05 | User non-aktif login | User is_active=false | Tidak bisa login / blocked | P0 |
| TC-002-06 | Loading state route | Navigasi ke route terlindungi | Skeleton tampil saat loading | P2 |

---

## TC-003 — Owner Dashboard

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-003-01 | Load dashboard | Buka /owner/dashboard | Semua metric cards tampil | P0 |
| TC-003-02 | Period harian | Pilih "Harian" | Data hari ini tampil | P1 |
| TC-003-03 | Period mingguan | Pilih "Mingguan" | Data 7 hari tampil | P1 |
| TC-003-04 | Period bulanan | Pilih "Bulanan" | Data bulan ini tampil | P1 |
| TC-003-05 | Navigasi mundur | Klik tombol ← | Data periode sebelumnya | P1 |
| TC-003-06 | Navigasi maju terbatas | Klik → di periode hari ini | Tombol disabled (tidak bisa ke masa depan) | P1 |
| TC-003-07 | Chart kosong | Tidak ada data | Empty state muncul, bukan chart kosong | P1 |
| TC-003-08 | Metric: total penjualan | Cek nilai | Sesuai data Supabase | P0 |
| TC-003-09 | Top menu items | Cek daftar | Urutan benar (qty tertinggi duluan) | P1 |
| TC-003-10 | Kasir performance | Cek tabel | Data per kasir akurat | P1 |
| TC-003-11 | Low stock alert | Stok di bawah minimum | Item muncul di bagian low stock | P1 |

---

## TC-004 — Branch Monitoring (CRUD Outlet)

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-004-01 | Lihat daftar outlet | Buka /owner/branches | List outlet dengan metric hari ini | P0 |
| TC-004-02 | Tambah outlet valid | Isi nama, kota, alamat, telp, pajak → Simpan | Outlet baru muncul di list | P0 |
| TC-004-03 | Tambah outlet — nama kosong | Submit tanpa nama | Validasi "nama wajib diisi" | P0 |
| TC-004-04 | Tambah outlet — nama < 2 char | Input "A" → Submit | Validasi min 2 karakter | P0 |
| TC-004-05 | Tambah outlet — pajak negatif | Input tax_percent = -5 | Validasi: min 0 | P1 |
| TC-004-06 | Tambah outlet — pajak > 100 | Input tax_percent = 150 | Validasi: max 100 | P1 |
| TC-004-07 | Edit outlet | Klik edit → ubah nama → Simpan | Nama terupdate | P0 |
| TC-004-08 | Edit outlet — nama kosong | Clear nama → Submit | Validasi muncul | P0 |
| TC-004-09 | Toggle aktif/nonaktif | Klik toggle outlet | Status berubah, badge berubah | P1 |
| TC-004-10 | Hapus outlet | Klik hapus → konfirmasi | Outlet hilang dari list | P0 |
| TC-004-11 | Hapus outlet — batalkan | Klik hapus → klik Batal | Outlet tetap ada | P1 |
| TC-004-12 | Detail outlet — klik buka | Klik nama/detail outlet | Sheet muncul dengan info lengkap | P1 |
| TC-004-13 | Low stock di detail outlet | Outlet punya stok kritis | Muncul di detail sheet | P1 |
| TC-004-14 | Omzet hari ini | Outlet aktif dengan transaksi | Nominal benar di list | P1 |

---

## TC-005 — Finance Report (Owner)

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-005-01 | Load report bulan ini | Buka /owner/finance | P&L bulan ini tampil | P0 |
| TC-005-02 | Ganti bulan | Pilih bulan lain dari picker | Data terupdate | P1 |
| TC-005-03 | Filter semua outlet | Pilih "Semua Cabang" | Data agregat semua outlet | P0 |
| TC-005-04 | Filter outlet spesifik | Pilih satu outlet | Data outlet tersebut saja | P0 |
| TC-005-05 | Net profit positif | Cek nilai | Warna hijau | P1 |
| TC-005-06 | Net profit negatif | Cek nilai (bulan rugi) | Warna merah | P1 |
| TC-005-07 | Tidak ada data | Bulan tanpa transaksi | Empty state: "Tidak ada data keuangan..." | P1 |
| TC-005-08 | Kalkulasi HPP | Cek nilai gross profit | = Gross Revenue - HPP | P0 |
| TC-005-09 | Kalkulasi net profit | Cek nilai | = Gross Profit - Expenses | P0 |

---

## TC-006 — Owner Staff Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-006-01 | Lihat semua staff | Buka /owner/staff | Semua staff semua outlet tampil | P0 |
| TC-006-02 | Tambah staff valid | Isi semua field → Simpan | Staff baru muncul | P0 |
| TC-006-03 | Tambah staff — email kosong | Submit tanpa email | Validasi muncul | P0 |
| TC-006-04 | Tambah staff — email invalid | Input "bukan-email" | Validasi format email | P0 |
| TC-006-05 | Tambah staff — password < 6 | Input password "abc" | Validasi min 6 karakter | P0 |
| TC-006-06 | Tambah staff — nama kosong | Submit tanpa nama | Validasi min 2 karakter | P0 |
| TC-006-07 | Tambah staff — outlet opsional | Tidak pilih outlet → Simpan | Staff dibuat, outlet_id=null (Semua Cabang) | P1 |
| TC-006-08 | Edit staff | Ubah nama/role/outlet → Simpan | Data terupdate | P0 |
| TC-006-09 | Edit staff — email tidak bisa diubah | Cek form edit | Field email disabled/tidak ada | P1 |
| TC-006-10 | Toggle aktif/nonaktif | Klik toggle | Status berubah | P1 |
| TC-006-11 | Role label benar | Cek badge | admin="Admin", manajer="Manajer", kasir="Kasir" | P2 |
| TC-006-12 | Avatar inisial | Staff tanpa foto | Inisial nama tampil | P2 |
| TC-006-13 | Outlet "Semua Cabang" | Staff outlet_id=null | Tampil italic "Semua cabang" | P2 |

---

## TC-007 — Admin Dashboard

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-007-01 | Load tanpa outlet | Buka /admin/dashboard saat outlet belum dipilih | Komponen NoOutlet tampil | P0 |
| TC-007-02 | Pilih outlet → load data | Pilih outlet dari header | Semua metric terload | P0 |
| TC-007-03 | Metric total penjualan | Cek angka | Sesuai data DB | P0 |
| TC-007-04 | Active orders realtime | Buka order baru dari POS | List active orders terupdate tanpa refresh | P1 |
| TC-007-05 | Low stock items | Item stok kritis | Muncul di dashboard | P1 |
| TC-007-06 | Table status | Meja occupied | Badge "Occupied" merah | P1 |
| TC-007-07 | Chart trend | Data harian ada | Grafik tampil | P1 |
| TC-007-08 | Chart kosong | Tidak ada data | Empty state grafik | P1 |
| TC-007-09 | Period filter | Ganti harian/mingguan/bulanan | Data berubah | P1 |
| TC-007-10 | Navigasi periode | Klik ← → | Data periode sebelumnya/berikutnya | P1 |

---

## TC-008 — Menu Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-008-01 | Lihat menu grid | Buka /admin/menu | Grid menu tampil dengan benar | P0 |
| TC-008-02 | Filter kategori | Klik kategori | Hanya menu kategori tersebut tampil | P1 |
| TC-008-03 | Cari menu | Ketik nama di search | Menu terfilter | P1 |
| TC-008-04 | Filter "Semua" | Klik Semua | Semua menu tampil | P1 |
| TC-008-05 | Tambah menu valid | Isi nama + harga → Simpan | Menu baru muncul di grid | P0 |
| TC-008-06 | Tambah menu — nama kosong | Submit tanpa nama | Validasi min 2 karakter | P0 |
| TC-008-07 | Tambah menu — harga 0 | Input harga = 0 | Validasi: harga harus > 0 | P0 |
| TC-008-08 | Tambah menu — harga negatif | Input harga = -1000 | Validasi harus positif | P0 |
| TC-008-09 | Upload gambar valid | Upload JPG/PNG < 5MB | Gambar tampil di preview + card | P1 |
| TC-008-10 | Upload gambar — file terlalu besar | Upload file > 5MB | Error "ukuran maks 5MB" | P1 |
| TC-008-11 | Upload gambar — format salah | Upload file .pdf | Error format tidak valid | P1 |
| TC-008-12 | Hapus gambar | Klik tombol hapus gambar | Gambar dihapus, placeholder tampil | P1 |
| TC-008-13 | Edit menu | Klik edit → ubah nama → Simpan | Nama terupdate | P0 |
| TC-008-14 | Hapus menu | Klik hapus → konfirmasi | Menu hilang dari grid | P0 |
| TC-008-15 | Tambah resep | Edit menu → pilih bahan → qty | Resep tersimpan | P1 |
| TC-008-16 | Tambah resep — duplikat bahan | Pilih bahan yang sudah ada di resep | Bahan tidak muncul lagi di dropdown | P1 |
| TC-008-17 | Hapus baris resep | Klik hapus di baris resep | Baris hilang | P1 |
| TC-008-18 | Availability toggle | Edit menu → ubah is_available | Badge "Habis"/"Tersedia" berubah | P1 |
| TC-008-19 | Featured toggle | Aktifkan is_featured | Badge "Featured" muncul di card | P2 |
| TC-008-20 | Tag menu | Input tags comma-separated | Tags tersimpan, diparsing benar | P2 |
| TC-008-21 | Select extras | Pilih extra option | Extras tersimpan di menu | P1 |

---

## TC-009 — Category Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-009-01 | Lihat kategori | Buka /admin/categories | Tabel kategori tampil | P0 |
| TC-009-02 | Tambah kategori valid | Input nama → Simpan | Kategori baru di tabel | P0 |
| TC-009-03 | Tambah kategori — nama kosong | Submit tanpa nama | Validasi muncul | P0 |
| TC-009-04 | Pilih ikon emoji | Klik salah satu dari 16 preset | Ikon terpilih tampil di preview | P1 |
| TC-009-05 | Input ikon custom | Ketik emoji custom | Ikon tersimpan | P2 |
| TC-009-06 | Sort order | Input angka sort_order | Urutan berubah | P2 |
| TC-009-07 | Assign department | Pilih department → Simpan | Badge department tampil | P1 |
| TC-009-08 | Filter by department | Klik tombol department | Hanya kategori dept tersebut | P1 |
| TC-009-09 | Edit kategori | Ubah nama → Simpan | Nama terupdate | P0 |
| TC-009-10 | Hapus kategori | Konfirmasi → hapus | Kategori hilang | P0 |
| TC-009-11 | Default ikon | Kategori tanpa ikon | Tampil ikon 📂 | P2 |

---

## TC-010 — Stock Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-010-01 | Lihat daftar stok | Buka /admin/stock | Tab List tampil bahan + qty | P0 |
| TC-010-02 | Badge stok OK | Qty > min_stock | Badge hijau "OK" | P1 |
| TC-010-03 | Badge stok low | Qty ≤ min_stock | Badge kuning "Low" | P1 |
| TC-010-04 | Badge stok critical | Qty ≤ 50% min_stock | Badge merah "Critical" | P1 |
| TC-010-05 | Badge out of stock | Qty ≤ 0 | Badge merah "Out of Stock" | P1 |
| TC-010-06 | Tambah bahan valid | Isi semua field → Simpan | Bahan baru di list | P0 |
| TC-010-07 | Tambah bahan — nama kosong | Submit tanpa nama | Validasi muncul | P0 |
| TC-010-08 | Tambah bahan — unit kosong | Submit tanpa unit | Validasi muncul | P0 |
| TC-010-09 | Ajdustment — pembelian | Pilih tipe Purchase, qty=10 → Simpan | Qty bertambah, history muncul | P0 |
| TC-010-10 | Adjustment — waste | Pilih tipe Waste, qty=5 → Simpan | Qty berkurang, history muncul | P0 |
| TC-010-11 | Adjustment — qty negatif | Input qty = -1 | Validasi/tombol minus diblokir | P0 |
| TC-010-12 | Adjustment — qty = 0 | Input qty = 0 → Submit | Validasi: qty harus > 0 | P0 |
| TC-010-13 | Riwayat transaksi | Klik tab Transaction History | List transaksi tampil | P1 |
| TC-010-14 | Warna perubahan qty | Lihat kolom change | Positif = hijau, negatif = merah | P2 |
| TC-010-15 | Edit bahan | Ubah nama/unit → Simpan | Data terupdate | P0 |
| TC-010-16 | Edit bahan — tidak bisa ubah qty | Cek form edit | Field qty tidak ada di form edit | P1 |
| TC-010-17 | Hapus bahan | Konfirmasi → hapus | Bahan hilang | P0 |

---

## TC-011 — Order List

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-011-01 | Lihat order list | Buka /admin/orders | Tabel order 7 hari terakhir | P0 |
| TC-011-02 | Filter by status | Pilih status "paid" | Hanya order paid tampil | P1 |
| TC-011-03 | Filter by tipe | Pilih "Dine In" | Hanya dine_in tampil | P1 |
| TC-011-04 | Filter date range | Pilih rentang tanggal | Hanya order dalam range | P1 |
| TC-011-05 | Lihat detail order | Klik nomor order | Sheet detail muncul | P0 |
| TC-011-06 | Detail — item list | Cek sheet | Semua item + qty + subtotal tampil | P1 |
| TC-011-07 | Detail — info payment | Order paid | Metode + nominal payment tampil | P1 |
| TC-011-08 | Detail — audit trail | Cek sheet | Timeline aksi tampil | P1 |
| TC-011-09 | Void order — eligible | Order status confirmed | Tombol Void tampil & aktif | P0 |
| TC-011-10 | Void order — konfirmasi | Klik void → isi alasan → konfirmasi | Status order berubah jadi void | P0 |
| TC-011-11 | Void order — batalkan | Klik void → klik Batal | Order tidak berubah | P1 |
| TC-011-12 | Void order — tidak eligible | Order status paid | Tombol Void tidak tampil | P0 |
| TC-011-13 | Void order — alasan kosong | Submit void tanpa alasan | Form bisa dikirim (alasan opsional) | P2 |
| TC-011-14 | Order type label | Cek kolom tipe | dine_in="Makan di Tempat", dll | P2 |
| TC-011-15 | Harga breakdown | Cek total di detail | Subtotal + discount + tax = total | P0 |

---

## TC-012 — Shift List

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-012-01 | Lihat daftar shift | Buka /admin/shifts | Tabel shift tampil | P0 |
| TC-012-02 | Buka shift valid | Pilih kasir → isi kas awal → Buka | Shift baru terbuat, banner aktif muncul | P0 |
| TC-012-03 | Buka shift — kasir tidak dipilih | Submit tanpa pilih kasir | Error "Pilih kasir terlebih dahulu" | P0 |
| TC-012-04 | Tutup shift valid | Klik tutup → isi kas akhir → Tutup | Shift tertutup, selisih terhitung | P0 |
| TC-012-05 | Tutup shift — kas pas | Kas akhir = expected | Badge "Sesuai", diff = 0 | P1 |
| TC-012-06 | Tutup shift — kas kurang | Kas akhir < expected | Badge "Kurang", diff merah | P1 |
| TC-012-07 | Tutup shift — kas lebih | Kas akhir > expected | Badge "Lebih", diff hijau | P1 |
| TC-012-08 | Banner shift aktif | Ada shift berjalan | Banner kuning tampil dengan info kasir | P1 |
| TC-012-09 | Navigasi periode | Klik ← → | Data periode berubah | P1 |
| TC-012-10 | Detail shift | Klik detail | Sheet dengan rekap kas + timeline | P1 |
| TC-012-11 | Tutup shift dari detail | Klik Tutup di sheet | Sheet close dialog muncul | P1 |
| TC-012-12 | Filter kasir di dropdown | Hanya kasir aktif di outlet | Kasir nonaktif tidak tampil | P1 |
| TC-012-13 | Kas awal opsional | Submit shift tanpa kas awal | Shift dibuat dengan kas 0 | P2 |

---

## TC-013 — Reports (5 Tab)

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-013-01 | Tab Daily Sales — load | Buka tab pertama | Chart + tabel tampil | P0 |
| TC-013-02 | Daily Sales — filter date | Ubah rentang tanggal | Data terupdate | P1 |
| TC-013-03 | Daily Sales — chart | Cek chart | Bar gross vs net | P1 |
| TC-013-04 | Daily Sales — export CSV | Klik Export CSV | File CSV terunduh | P1 |
| TC-013-05 | Daily Sales — export Excel | Klik Export Excel | File Excel terunduh | P1 |
| TC-013-06 | Daily Sales — export PDF | Klik Export PDF | File PDF terunduh | P1 |
| TC-013-07 | Tab Transaction History | Klik tab | Tabel order tampil | P0 |
| TC-013-08 | History — filter status | Pilih status | Filtered | P1 |
| TC-013-09 | History — export | Export CSV | File terunduh | P1 |
| TC-013-10 | Tab Top Menu | Klik tab | Chart + ranking tampil | P0 |
| TC-013-11 | Top Menu — urutan | Cek ranking | Item terlaris di posisi 1 | P1 |
| TC-013-12 | Top Menu — % total | Cek kolom % | Benar: qty_item / total_qty * 100 | P1 |
| TC-013-13 | Tab Payment Methods | Klik tab | Pie chart + breakdown tampil | P0 |
| TC-013-14 | Payment — pie chart | Cek visualisasi | Proporsi benar per metode | P1 |
| TC-013-15 | Tab Finance (P&L) | Klik tab | P&L statement tampil | P0 |
| TC-013-16 | Finance — net profit hijau | Profit > 0 | Warna hijau | P1 |
| TC-013-17 | Finance — net profit merah | Profit < 0 | Warna merah | P1 |
| TC-013-18 | Finance — margin % | Cek nilai | = (Net Profit / Gross Revenue) * 100 | P1 |
| TC-013-19 | Tidak ada data | Semua tab tanpa data | Empty state muncul | P1 |

---

## TC-014 — Promo Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-014-01 | Lihat promo | Buka /admin/promos | Tabel promo tampil | P0 |
| TC-014-02 | Tambah promo — persentase | Tipe=%, value=10 | Promo baru, value tampil "10%" | P0 |
| TC-014-03 | Tambah promo — fixed | Tipe=Fixed, value=5000 | Value tampil sebagai Rp 5.000 | P0 |
| TC-014-04 | Tambah promo — nama kosong | Submit tanpa nama | Validasi min 2 karakter | P0 |
| TC-014-05 | Tambah promo — nama < 2 char | Input "A" | Validasi muncul | P0 |
| TC-014-06 | Promo dengan tanggal | Set start + end date | Periode tampil di tabel | P1 |
| TC-014-07 | Promo tanpa tanggal | Kosongkan dates | Tampil "Selamanya" | P1 |
| TC-014-08 | Promo dengan limit | Set usage_limit=100 | Tampil "0 / 100" | P1 |
| TC-014-09 | Edit promo | Ubah value → Simpan | Terupdate | P0 |
| TC-014-10 | Toggle aktif/nonaktif | Klik toggle | Status badge berubah | P1 |

---

## TC-015 — Loyalty Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-015-01 | Lihat member | Buka /admin/loyalty | Tabel member + summary cards | P0 |
| TC-015-02 | Tambah member valid | Isi phone + nama → Simpan | Member baru di tabel | P0 |
| TC-015-03 | Tambah member — phone < 8 digit | Input "1234567" | Validasi min 8 karakter | P0 |
| TC-015-04 | Tambah member — nama kosong | Submit tanpa nama | Validasi muncul | P0 |
| TC-015-05 | Tambah member — duplikat phone | Phone sudah terdaftar | Error "Nomor HP sudah terdaftar" | P0 |
| TC-015-06 | Search by nama | Ketik nama | Filter sesuai | P1 |
| TC-015-07 | Search by phone | Ketik nomor | Filter sesuai | P1 |
| TC-015-08 | Tier badge | Member dengan poin berbeda | Tier bronze/silver/gold/platinum benar | P1 |
| TC-015-09 | Adjust poin — tambah | Klik adjust → poin positif + desc | Poin bertambah | P0 |
| TC-015-10 | Adjust poin — kurangi | Poin negatif + desc | Poin berkurang | P0 |
| TC-015-11 | Adjust poin — desc kosong | Submit tanpa deskripsi | Validasi min 1 karakter | P0 |
| TC-015-12 | Adjust poin — nilai 0 | Input 0 → submit | Validasi: tidak boleh 0 | P0 |
| TC-015-13 | Detail member | Klik nama | Sheet detail + histori transaksi | P1 |
| TC-015-14 | Edit member — nama | Ubah nama → Simpan | Nama terupdate | P0 |
| TC-015-15 | Toggle aktif member | Klik toggle | Status berubah | P1 |
| TC-015-16 | Summary cards | Cek angka | Total/aktif/poin/tier akurat | P1 |

---

## TC-016 — Table Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-016-01 | Lihat meja | Buka /admin/tables | Grid meja tampil | P0 |
| TC-016-02 | Meja tanpa area | Semua meja tanpa area | Tidak ada heading area | P1 |
| TC-016-03 | Meja dengan area | Ada berbagai area | Grouped by area dengan heading | P1 |
| TC-016-04 | Status meja | Cek badge | available=hijau, occupied=merah, dll | P1 |
| TC-016-05 | Tambah meja valid | Nomor + kapasitas → Simpan | Meja baru di grid | P0 |
| TC-016-06 | Tambah meja — nomor kosong | Submit tanpa nomor | Validasi muncul | P0 |
| TC-016-07 | Tambah meja — kapasitas < 1 | Input 0 | Validasi min 1 | P0 |
| TC-016-08 | Tambah meja dengan area | Isi area "VIP" | Meja masuk grup VIP | P1 |
| TC-016-09 | Edit meja | Ubah kapasitas → Simpan | Terupdate | P0 |
| TC-016-10 | Realtime update | Order masuk → meja jadi occupied | Badge berubah tanpa refresh | P1 |

---

## TC-017 — Expense Manager

| ID | Skenario | Langkah | Expected Result | Prioritas |
|----|----------|---------|-----------------|-----------|
| TC-017-01 | Lihat pengeluaran bulan ini | Buka /admin/expenses | List + summary cards | P0 |
| TC-017-02 | Ganti bulan | Pilih bulan lain | Data berubah | P1 |
| TC-017-03 | Tambah pengeluaran valid | Isi semua field → Simpan | Record baru di tabel | P0 |
| TC-017-04 | Tambah — tanggal kosong | Submit tanpa tanggal | Validasi muncul | P0 |
| TC-017-05 | Tambah — kategori kosong | Submit tanpa kategori | Validasi muncul | P0 |
| TC-017-06 | Tambah — amount kosong | Submit tanpa amount | Validasi muncul | P0 |
| TC-017-07 | Edit pengeluaran | Ubah amount → Simpan | Terupdate | P0 |
| TC-017-08 | Hapus pengeluaran | Konfirmasi → hapus | Record hilang, total berkurang | P0 |
| TC-017-09 | Hapus — batalkan | Klik Batal | Record tetap ada | P1 |
| TC-017-10 | Summary per kategori | Cek summary cards | Total per kategori akurat | P1 |
| TC-017-11 | Badge kategori | Cek warna | bahan_baku=orange, gaji=purple, dll | P2 |

---

## TC-018 — Negative Cases Lintas Fitur

| ID | Skenario | Expected Result | Prioritas |
|----|----------|-----------------|-----------|
| TC-018-01 | Refresh page saat authenticated | Tetap login, data reload | P0 |
| TC-018-02 | Navigasi browser back/forward | Halaman benar, tidak crash | P1 |
| TC-018-03 | Internet putus saat load data | Error state tampil, bukan crash | P1 |
| TC-018-04 | Submit form 2x cepat | Hanya 1 request dikirim (button disabled) | P0 |
| TC-018-05 | Input XSS di form | Script tidak tereksekusi | P0 |
| TC-018-06 | Input SQL injection di form | Query aman, tidak ada error SQL | P0 |
| TC-018-07 | Outlet tidak dipilih — semua admin page | NoOutlet component tampil | P0 |
| TC-018-08 | Data sangat banyak (1000+ records) | Tabel masih responsif | P2 |
| TC-018-09 | Session expired saat mengisi form | Redirect ke login, data form hilang | P1 |
| TC-018-10 | Concurrent edit oleh 2 user | Data terakhir yang tersimpan | P2 |

# Regression Checklist — Pre-Release Smoke Test

**Versi:** 1.0
**Tanggal:** 2026-05-28

Checklist ini WAJIB diselesaikan sebelum setiap rilis production. Tandai ✅ jika PASS, ❌ jika FAIL.

> **Cara pakai:** Salin checklist ini ke issue/PR, ceklis manual. Untuk rilis besar, tag QA Engineer sebagai approver akhir.

---

## 0. Environment Setup

- [ ] Production build sukses: `npm run build` exit code 0
- [ ] TypeScript check pass: `tsc --noEmit` exit code 0
- [ ] Lint pass: `npm run lint` exit code 0
- [ ] API test suite pass: `node --test tests/api/*.test.mjs` (16/18 saat ini, target 18/18)
- [ ] Migration database up-to-date di production
- [ ] Source maps tidak ter-deploy (`find dist -name '*.map'` kosong)
- [ ] Chunk names obscured (cek 1-2 file di `dist/assets/` — harus hash-only)

---

## 1. Authentication

- [ ] **TC-AUTH-01** Login akun QA dari `E2E_EMAIL` valid → redirect ke `/dashboard`
- [ ] **TC-AUTH-02** Login dengan password salah → error
- [ ] **TC-AUTH-07** Logout dari sidebar → redirect ke `/login`
- [ ] **TC-AUTH-08** Akses `/admin/dashboard` tanpa login → redirect `/login`

## 2. Dashboard

### Owner (`/owner/dashboard`)
- [ ] Page load < 5 detik
- [ ] Stat cards menampilkan angka (bukan NaN, undefined, atau Rp0 jika ada data)
- [ ] Outlet selector berfungsi
- [ ] **(BUG-LAP-API-002 fix)** Payment widget menampilkan data
- [ ] **(BUG-LAP-API-003 fix)** Kasir leaderboard menampilkan data

### Admin (`/admin/dashboard`)
- [ ] Page load < 5 detik
- [ ] Realtime order baru muncul tanpa refresh
- [ ] Active orders count akurat

## 3. Produk

### Menu (`/admin/menu`)
- [ ] List menu render
- [ ] Tambah menu baru → muncul di list
- [ ] Edit harga → harga update
- [ ] Toggle out-of-stock → mobile POS reflect
- [ ] Search/filter berfungsi

### Departments & Categories
- [ ] CRUD departemen lengkap
- [ ] CRUD kategori dengan link ke departemen

### Extras
- [ ] CRUD extras + opsi
- [ ] Harga opsi tampil benar di form

## 4. Laporan (KRITIS)

### Ringkasan Penjualan (`/admin/reports`)
- [ ] 5 stat cards render dengan nilai benar (Total Penjualan, Transaksi, Bersih, Pembayaran, Piutang)
- [ ] Tabel transaksi 8 kolom render
- [ ] Kolom Bayar/Order = nama kasir (bukan UUID)
- [ ] Kolom Waktu Bayar = "—" untuk order belum bayar
- [ ] Date picker — preset "Hari Ini", "7 Hari", "Bulan Lalu" benar
- [ ] Date picker — custom range bekerja
- [ ] Search filter realtime
- [ ] Export CSV → download
- [ ] Export Excel → header oranye, kolom rapi, no overlap
- [ ] Export PDF → layout rapi

### Sales Breakdown (`/admin/sales-breakdown/:tab`)
- [ ] Tab Departemen render + 4 stat cards
- [ ] Tab Kategori render — multi-month range tidak hilang data (regresi BUG-LAP-003)
- [ ] Tab Kategori tidak crash — `total_orders` ada (regresi BUG-LAP-005)
- [ ] Tab Menu render
- [ ] Tab Extra render
- [ ] Tab Pajak render — 3 stat cards + Hari/Bulan/Tahun toggle
- [ ] **(regresi BUG-LAP-001)** Tidak ada nilai Rp0 di semua tab (currency prop `value`, bukan `amount`)
- [ ] Export per tab CSV/Excel/PDF — semua tab ada PDF (Extra tab juga)
- [ ] Sidebar navigation → URL aktif benar

## 5. Pesanan

### Daftar Pesanan (`/admin/orders`)
- [ ] List orders render
- [ ] Realtime order baru muncul
- [ ] Filter status berfungsi
- [ ] Detail order menampilkan items
- [ ] Void order — status berubah + reason tersimpan

### Shift Kasir (`/admin/shifts`)
- [ ] List shift render
- [ ] Buka shift baru
- [ ] Tutup shift dengan cash difference

## 6. Inventori

### Stok (`/admin/stock`)
- [ ] List bahan baku render
- [ ] Stock in/out/adjustment berfungsi
- [ ] Low stock alert highlight merah

### Laporan Stok (`/admin/stock-report`)
- [ ] List transaksi stok render
- [ ] Filter by tipe (in/out)

## 7. Keuangan

### Pengeluaran (`/admin/expenses`)
- [ ] Tambah pengeluaran
- [ ] Upload bukti < 2MB

### Laporan Keuangan (`/owner/finance`)
- [ ] P&L bulan terpilih render
- [ ] Margin (gross & net) akurat

## 8. Operasional

### Tables (`/admin/tables`)
- [ ] CRUD meja
- [ ] Status realtime (terpakai / kosong)

### QR Code (`/admin/qr-codes`)
- [ ] Generate QR per meja
- [ ] Download QR
- [ ] Scan QR di mobile → buka menu meja tersebut

## 9. Promosi & Loyalty

- [ ] CRUD promo
- [ ] Promo expired tidak bisa dipakai
- [ ] List member loyalty render

## 10. Pembayaran

### Payment Methods (`/admin/payments`)
- [ ] List metode render
- [ ] Toggle non-aktif → mobile POS tidak menampilkan

### Tax Settings (`/admin/taxes`)
- [ ] Set persentase pajak
- [ ] Pilih order type kena pajak
- [ ] Order baru otomatis kena pajak sesuai setting

### Receipt (`/admin/receipt`)
- [ ] Setting header/footer struk tersimpan

## 11. SDM

### Staff (`/admin/staff` & `/owner/staff`)
- [ ] List staff render dengan role + outlet
- [ ] Tambah staff → bisa login
- [ ] Edit role staff
- [ ] **(owner only)** Hapus staff → terhapus dari auth.users

## 12. Settings (`/admin/settings`)

- [ ] Edit info outlet (nama, alamat)
- [ ] Upload logo outlet

## 13. Cross-Cutting

### Performance
- [ ] First Contentful Paint < 3 detik di koneksi 4G
- [ ] Dashboard data load < 5 detik
- [ ] Tabel 1000+ rows tidak freeze browser

### Security
- [ ] **TC-SEC-01** RLS — anon role return `[]` (tidak bocor)
- [ ] **TC-SEC-02** Admin outlet A tidak bisa baca data outlet B
- [ ] **TC-SEC-03** XSS — `<script>` di input field di-escape
- [ ] **TC-SEC-04** Source maps tidak ter-deploy
- [ ] **TC-SEC-05** Chunk names hash-only di DevTools Sources

### Mobile Responsive (375x667, Android Chrome)
- [ ] Sidebar collapse + hamburger button bekerja
- [ ] Dashboard stat cards 2 kolom
- [ ] Tabel scroll horizontal (tidak crash)
- [ ] Date picker popup masuk viewport
- [ ] Form input tidak overflow
- [ ] Cek 5 halaman utama: dashboard, menu, reports, orders, staff

### Browser Compatibility
- [ ] Chrome desktop latest
- [ ] Safari macOS latest
- [ ] Firefox latest
- [ ] Mobile Chrome Android
- [ ] Mobile Safari iOS (optional jika user base sedikit)

### Error Handling
- [ ] Offline mode → error toast, no crash
- [ ] Empty state → pesan "Tidak ada data" + ikon
- [ ] 404 page → halaman 404 atau redirect ke dashboard

---

## Bug Status Pre-Release

| Bug ID | Severity | Status | Required for release? |
|---|---|---|---|
| BUG-LAP-API-001 (Login broken) | BLOCKER | OPEN | ✅ YES — must fix |
| BUG-LAP-API-002 (v_payment_summary LIKE) | HIGH | OPEN | ✅ YES — must fix |
| BUG-LAP-API-003 (v_kasir_performance.shift_date) | HIGH | OPEN | ✅ YES — must fix |
| BUG-LAP-001 (CurrencyDisplay amount→value) | HIGH | FIXED | ✅ verify regression |
| BUG-LAP-002 (Receipt icon import) | LOW | FIXED | — |
| BUG-LAP-003 (KategoriTab month filter) | MEDIUM | FIXED | ✅ verify regression |
| BUG-LAP-005 (orders.toLocaleString crash) | HIGH | FIXED | ✅ verify regression |

---

## Sign-Off

| Role | Nama | Tanggal | Status |
|---|---|---|---|
| QA Engineer | _____________ | __________ | ☐ APPROVED ☐ REJECTED |
| Tech Lead | _____________ | __________ | ☐ APPROVED ☐ REJECTED |
| Product Manager | _____________ | __________ | ☐ APPROVED ☐ REJECTED |

**Release tag setelah semua sign-off:** `git tag v1.0.0 && git push --tags`

---

## Quick Smoke (15 menit)

Jika waktu terbatas, minimum jalankan ini:

1. ✅ Login → dashboard load
2. ✅ Buka /admin/reports → stat + tabel render
3. ✅ Buka /admin/sales-breakdown/kategori → tidak crash
4. ✅ Export Excel dari /admin/reports → file download + kolom rapi
5. ✅ Mobile 375px — sidebar collapse + tabel scroll
6. ✅ Logout → redirect /login
7. ✅ Akses /admin/dashboard tanpa login → redirect /login

Jika 1 dari 7 di atas FAIL → **DO NOT RELEASE**.

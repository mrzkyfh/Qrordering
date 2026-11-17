# Demo Data & Simulation Scripts

Folder ini berisi skrip SQL untuk **mengisi data master**, **mensimulasikan transaksi**, dan **menghapus** semua data demo agar laporan kelihatan berisi.

## 📁 File

| File | Tujuan |
|------|--------|
| `RELATION_ANALYSIS.md` | Analisis status relasi semua modul (sudah/belum tersambung) |
| `seed_demo_data.sql` | Isi master data: menu_extras, promos, vouchers, members, expenses, ingredient cost, recipes (idempoten, semua outlet aktif) |
| `simulate_transactions.sql` | Generate ~40 transaksi tersimulasi per outlet, pakai extras + promo + loyalty + shift |
| `cleanup_demo_data.sql` | Hapus semua data demo + simulasi |
| `reset_all_data_keep_owner.sql` | Factory reset seluruh data operasional dan akun selain satu owner terpilih |

## 🚀 Cara pakai

### Step 1 — Apply migrations terlebih dahulu
Pastikan migration `039`, `040`, `041`, `042` sudah jalan. Cek di Supabase Dashboard → Database → Tables → harus ada `menu_extras`, `menu_extra_options`, `menu_item_extras`. Cek juga di Database → Views → harus ada `v_order_hpp`.

### Step 2 — Seed master data
1. Buka Supabase Dashboard → SQL Editor
2. Paste isi `seed_demo_data.sql`
3. Run. Lihat NOTICE output per outlet
4. Ringkasan terakhir menampilkan jumlah extras/promos/vouchers/members/expenses per outlet

### Step 3 — Simulasi transaksi
1. Paste isi `simulate_transactions.sql`
2. Run. Akan generate ~40 order paid + beberapa void/cancelled per outlet
3. Cek ringkasan untuk:
   - `paid_orders / void / cancelled`
   - `with_promo` (jumlah pakai voucher)
   - `with_member` (jumlah link member)
   - `with_shift` (jumlah link shift kasir)
   - `revenue` (total pendapatan)
4. Cek juga tabel `loyalty earn` dan `promo usage` di bawahnya

### Step 4 — Verifikasi via UI
Buka Owner Panel di browser:
- **Ringkasan Penjualan** — angka Pendapatan, Biaya Promosi, HPP, Biaya Operasional, Laba Kotor, Laba Bersih semuanya terisi
- **Detail Penjualan** — daftar transaksi muncul (filter SIM-* untuk lihat hanya simulasi)
- **Departemen / Kategori / Menu** — breakdown ada
- **Sub Extra** — `v_extra_option_sales` ada angka per opsi (Topping, Saus, dll)
- **Pajak / Service Charge** — breakdown harian ada
- **Manajemen Promo** — usage_count > 0 untuk promo demo
- **Manajemen Loyalty** — saldo points members bertambah, transaksi earn ada riwayat

### Step 5 — Cleanup (kapan saja)
1. Paste `cleanup_demo_data.sql` di SQL Editor
2. Run. Verifikasi tabel akhir menampilkan `sisa = 0` untuk semua marker

### Factory reset sebelum go-live

Jika bukan hanya data demo yang perlu dihapus, gunakan
`reset_all_data_keep_owner.sql`. Script ini menghapus seluruh data bisnis,
outlet, staf, dan akun Auth lain, tetapi mempertahankan satu akun owner serta
`app_config`. Backup database dan baca instruksi di bagian atas file sebelum
menjalankannya. Seluruh Supabase Storage bucket dan Cloudflare R2 bucket
`time420s-images` harus dikosongkan lebih dahulu. Script otomatis batal jika
Supabase Storage masih berisi file dan meminta konfirmasi operator eksplisit
bahwa R2 sudah kosong karena SQL Supabase tidak dapat memeriksa Cloudflare.

## ⚠️ Catatan penting

### Idempotensi
- `seed_demo_data.sql` aman dijalankan ulang (cek IF NOT EXISTS / kondisi sebelum insert)
- `simulate_transactions.sql` **TIDAK** idempoten — setiap kali run akan menambah 40 order baru per outlet. Jalankan cleanup dulu sebelum re-simulate

### Data yang sulit di-reverse oleh cleanup
- `menu_recipes` yang dibuat dari §8 seed tidak punya marker spesifik (link generik ke ingredient pertama). Cleanup script tidak menghapusnya. Hapus manual via owner panel jika perlu
- `ingredients.cost_per_unit` yang di-update dari §7 seed: setelah cleanup, nilai tetap. Reset ke 0 manual jika perlu

### Shift simulasi
- Setiap kali jalankan `simulate_transactions.sql`, dibuat 1 shift baru per outlet dengan note `[DEMO-SIM] Shift simulasi`
- Cleanup script akan hapus semua shift dengan note tersebut

### Loyalty points
- Cleanup akan reset saldo `loyalty_members.points` ke nilai awal seed (1500, 6200, 350, 25000, 800)
- Jika kamu modify saldo via owner panel, cleanup akan overwrite — backup dulu jika perlu

## 📊 Skenario yang diuji oleh simulasi

| # | Skenario | Cara verifikasi |
|---|----------|-----------------|
| 1 | Order dengan menu_extras | `SELECT * FROM v_extra_option_sales WHERE qty_selected > 0` |
| 2 | Order dengan voucher promo | `SELECT * FROM promos WHERE name LIKE '%DEMO%' AND usage_count > 0` |
| 3 | Order dengan member loyalty | `SELECT * FROM loyalty_transactions WHERE type = 'earn' ORDER BY created_at DESC` |
| 4 | Kasir order dalam shift | `SELECT COUNT(*) FROM orders WHERE order_number LIKE 'SIM-%' AND shift_id IS NOT NULL` |
| 5 | HPP per order | `SELECT * FROM v_order_hpp ORDER BY hpp_total DESC LIMIT 10` |
| 6 | Expenses untuk Laba Bersih | `SELECT category, SUM(amount) FROM expenses WHERE description LIKE '[DEMO]%' GROUP BY category` |
| 7 | Variasi status (paid/void/cancelled) | `SELECT status, COUNT(*) FROM orders WHERE order_number LIKE 'SIM-%' GROUP BY status` |

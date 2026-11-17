# Analisis Relasi Sistem — Time420s POS
**Status:** Post-Fix #1, #2, #3, #4 (kode sudah selesai, migrasi 039–042 sudah di-apply)
**Tanggal review:** 2026-05-30

---

## ✅ Relasi yang SUDAH TERHUBUNG dengan benar

### 1. `orders` ↔ `menu_extras` ↔ `order_item_options` ✓
**Status:** Tabel + insert logic + view aggregat **lengkap**

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema | ✓ | `039_menu_extras_schema.sql`, `038_order_item_options.sql` |
| Owner panel input | ✓ | `ExtraManager.tsx` — CRUD master extras |
| POS Mobile insert | ✓ | `pos_datasource.dart` createOrder — loop `cart.selectedExtras` → `order_item_options` |
| Customer Menu insert | ✓ | `customer-menu/app.js` submitOrder — sama |
| Laporan agregat | ✓ | view `v_extra_option_sales` (Sub Extra report) |

**Yang masih harus diisi (data):** `menu_extras`, `menu_extra_options`, `menu_item_extras` per outlet (kosong di production).

---

### 2. `orders` ↔ `promos`/`vouchers` ✓
**Status:** Validate + apply via RPC SECURITY DEFINER **lengkap**

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema | ✓ | `002_tables.sql`, `040_promo_validation_rpcs.sql` |
| Owner panel input | ✓ | `PromoManager.tsx` |
| RPC validasi | ✓ | `validate_promo_code()` — return discount_amount tanpa mutasi |
| RPC klaim | ✓ | `apply_promo_usage()` — increment usage_count atomik |
| POS Mobile | ✓ | PosBloc `PosPromoApplied` → discount masuk ke `orders.discount_amount` |
| Customer Menu | ✓ | `applyPromoCode()` di app.js, anon-callable via SECURITY DEFINER |
| Laporan agregat | ✓ | tergambar di Ringkasan Penjualan "Biaya Promosi" |

**Yang masih harus diisi:** Promo aktif + voucher code di setiap outlet.

---

### 3. `orders` ↔ `loyalty_members` ↔ `loyalty_transactions` ✓
**Status:** Earn otomatis post-payment **lengkap**

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema | ✓ | `014_loyalty.sql`, `041_loyalty_order_integration.sql` |
| Kolom `orders.loyalty_member_id` | ✓ | migration 041 |
| RPC lookup | ✓ | `find_loyalty_member_by_phone()` — anon callable |
| RPC earn | ✓ | `award_loyalty_points()` — SECURITY DEFINER, **idempoten** (cek `loyalty_transactions` by order_id) |
| POS Mobile | ✓ | PosBloc `PosLoyaltyLookup` + payment_page call `awardLoyaltyPoints` |
| Customer Menu | ✓ | `lookupMember()` + call `award_loyalty_points` di submitOrder |
| Rate config | ✓ | dari `outlets.loyalty_settings.points_per_rupiah` |

**Yang masih harus diisi:** Loyalty members per outlet untuk testing.

---

### 4. `orders` ↔ `shifts` ✓ (POS Mobile saja)
**Status:** Shift_id otomatis di-set saat kasir buat order

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema | ✓ | `002_tables.sql` line 88-100 |
| POS Mobile fetch active shift | ✓ | `pos_datasource.dart` createOrder — query `shifts WHERE end_time IS NULL` |
| Order insert | ✓ | `orders.shift_id` di-set otomatis |
| Customer Menu | **N/A** | Self-order (anon) memang tidak terkait shift kasir |
| Laporan | ✓ | `v_kasir_performance` per shift akurat |

---

### 5. `orders` ↔ `menu_recipes` ↔ `ingredients` (HPP) ✓
**Status:** View agregat untuk Laba Kotor **lengkap**

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema recipe | ✓ | `009_inventory_recipes.sql` |
| View HPP | ✓ | `v_order_hpp` (migration 042) |
| Ringkasan Penjualan | ✓ | `SalesSummary.tsx` query `v_order_hpp` |

**Yang masih harus diisi:** `ingredients.cost_per_unit` (banyak yang `0` → HPP otomatis 0), `menu_recipes` (menu tanpa resep tidak punya HPP).

---

### 6. `orders` ↔ `expenses` (Laba Bersih) ✓
**Status:** Date-range query di Ringkasan Penjualan

| Layer | Status | Lokasi |
|-------|--------|--------|
| Schema | ✓ | `002_tables.sql` |
| Owner panel CRUD | ✓ | `ExpenseManager.tsx` |
| Ringkasan Penjualan | ✓ | inline query di SalesSummary |

**Yang masih harus diisi:** `expenses` records per outlet (kosong → Laba Bersih = Laba Kotor).

---

### 7. `orders` ↔ `stock_transactions` (auto-deduct) ✓
**Status:** Trigger otomatis saat status berubah ke `paid`/`confirmed`

| Layer | Status | Lokasi |
|-------|--------|--------|
| Trigger | ✓ | `004_functions_triggers.sql` `deduct_stock_for_order` |
| Anti-double | ✓ | `010_fix_double_stock_mutation.sql` |

---

## ⚠️ Relasi yang TERHUBUNG TAPI PERLU DATA MASTER

Berikut tabel-tabel yang **schema + code path lengkap** tapi datanya **kosong** sehingga laporan belum berisi. Akan diisi oleh `seed_demo_data.sql`:

| Tabel | Kenapa perlu | File seed |
|-------|--------------|-----------|
| `menu_extras` + `menu_extra_options` | Tanpa ini, UI extras di POS/customer menu tidak muncul, dan `v_extra_option_sales` kosong | seed_demo_data.sql §2 |
| `menu_item_extras` | Tanpa link, menu item tidak menampilkan extras meskipun extras-nya ada | seed_demo_data.sql §3 |
| `promos` + `vouchers` | Kasir/pelanggan tidak bisa apply diskon | seed_demo_data.sql §4 |
| `loyalty_members` | Lookup HP selalu gagal | seed_demo_data.sql §5 |
| `expenses` | Laba Bersih = Laba Kotor (tidak akurat) | seed_demo_data.sql §6 |
| `ingredients.cost_per_unit` | HPP selalu 0 | seed_demo_data.sql §7 (update) |
| `menu_recipes` | Menu tanpa resep tidak punya HPP | seed_demo_data.sql §8 |

---

## ❌ Relasi yang MASIH PUTUS (di luar scope fix #1–4)

Ini gap arsitektural yang belum di-cover, untuk roadmap berikutnya:

### A. Loyalty Redeem (tukar poin)
- **Schema:** `loyalty_transactions.type = 'redeem'` tersedia
- **Code:** Belum ada UI/RPC untuk tukar poin saat checkout
- **Dampak:** Member tidak bisa pakai poin untuk diskon
- **Effort:** Sedang — perlu RPC `redeem_loyalty_points(member_id, points, order_id)` + UI input poin di checkout

### B. Tier auto-upgrade
- **Schema:** `loyalty_members.tier`, `outlets.loyalty_settings.tier_threshold`
- **Code:** Tidak ada trigger/RPC auto-upgrade berdasarkan total points
- **Dampak:** Tier selalu `bronze` walau poin sudah tinggi
- **Effort:** Rendah — trigger `AFTER UPDATE ON loyalty_members WHEN points changed`

### C. Promo type `bundling` & `bogo`
- **Schema:** Type sudah ada di enum
- **Code:** `validate_promo_code` return discount=0 untuk type ini
- **Dampak:** Owner panel filter type ini saat create, jadi tidak terbentur
- **Effort:** Tinggi — perlu skema item/qty + logika kompleks

### D. Customer menu shift_id
- **Status:** Self-order (anon) tidak link ke shift kasir karena memang tidak ada kasir
- **Dampak:** Self-order tidak muncul di laporan per-shift, hanya per-outlet/hari
- **Mitigasi alternatif:** Anggap self-order sebagai "shift-less revenue" dan tampilkan terpisah di laporan

### E. Customer menu loyalty redeem (anon)
- **Status:** Self-order bisa earn tapi tidak bisa redeem (butuh auth)
- **Effort:** Bisa via SECURITY DEFINER RPC dengan validasi nomor HP

### F. Restore menu_item / ingredient
- **RPC:** `restore_menu_item`, `restore_ingredient` ada (migration 037)
- **UI:** Belum ada button di owner panel
- **Effort:** Rendah

### G. Komisi kasir per shift / per order
- **Schema:** Tidak ada kolom komisi
- **Dampak:** Tabel "Komisi" di Ringkasan Penjualan dihapus karena tidak ada datanya

### H. MDR (Merchant Discount Rate) fee per metode payment
- **Schema:** Tidak ada kolom fee per payment_method
- **Dampak:** Tabel "Biaya MDR" di Ringkasan Penjualan dihapus

### I. Pembulatan, Ongkos Kirim, Asuransi, Platform fee
- **Schema:** Tidak di-track per order
- **Dampak:** Tidak tampil di laporan

---

## 📊 Skor Kelengkapan per Modul

| Modul | Schema | Backend | UI POS | UI Owner Panel | Data Master | Laporan | Skor |
|-------|--------|---------|--------|----------------|-------------|---------|------|
| Order flow | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **6/6 ✓** |
| Menu Extras | ✓ | ✓ | ✓ | ✓ | ⚠️ kosong | ✓ | 5/6 |
| Promo/Voucher | ✓ | ✓ | ✓ | ✓ | ⚠️ kosong | ✓ | 5/6 |
| Loyalty earn | ✓ | ✓ | ✓ | ✓ | ⚠️ kosong | ✓ | 5/6 |
| Loyalty redeem | ✓ | ❌ | ❌ | ❌ | — | ❌ | 1/6 |
| Shift link | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 6/6 ✓ |
| HPP | ✓ | ✓ | — | ✓ | ⚠️ partial | ✓ | 5/6 |
| Expenses | ✓ | ✓ | — | ✓ | ⚠️ kosong | ✓ | 5/6 |
| Stock auto-deduct | ✓ | ✓ | — | ✓ | ✓ | ✓ | 6/6 ✓ |

**Kesimpulan:** Semua relasi inti **sudah tersambung di code level**. Yang tersisa adalah **mengisi data master** (akan dikerjakan oleh `seed_demo_data.sql`) dan beberapa fitur lanjutan (loyalty redeem, tier upgrade) yang masuk roadmap berikutnya.

---

## 🧪 Rencana Pengujian End-to-End

Lihat `simulate_transactions.sql` untuk skrip yang menjalankan skenario berikut:

1. **Order dengan extras** — Customer pilih menu yang punya extras → `order_item_options` terisi → laporan Sub Extra menampilkan opsi terlaris
2. **Order dengan promo** — Kasir/customer apply voucher → `discount_amount > 0` → `vouchers.usage_count` bertambah → laporan Biaya Promosi terlihat
3. **Order dengan member** — Lookup HP → setelah paid, `loyalty_transactions(type='earn')` masuk → saldo `loyalty_members.points` bertambah
4. **Order kasir dalam shift** — Kasir buka shift → bayar order → `orders.shift_id` terisi → laporan kasir per shift akurat
5. **Order dengan HPP** — Menu yang punya resep → `v_order_hpp` return nilai > 0 → Laba Kotor di Ringkasan Penjualan akurat
6. **Expenses** — Insert pengeluaran → Ringkasan menampilkan Laba Bersih akurat (Laba Kotor - Biaya Operasional)
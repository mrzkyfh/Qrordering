# Mobile Feature Audit — QR Ordering POS
**Tanggal:** 2026-07-05
**Auditor:** Mobile Developer
**Stack:** Flutter + BLoC + go_router + Supabase (verified — bukan React Native)
**Scope:** `apps/mobile/qrordering` — audit fitur: apa yang sudah ada vs apa yang belum & sebaiknya dibuat

---

## Ringkasan

Aplikasi sudah **matang untuk POS F&B single/multi-outlet**. Modul inti lengkap. Audit ini fokus ke **gap fitur** — diurutkan by impact operasional, bukan menulis ulang yang sudah ada.

**Verdict:** Tidak ada gap yang membuat POS tak bisa dipakai. Ada **2 gap HIGH** yang berdampak ke akurasi kas & keandalan offline, sisanya enhancement.

---

## ✅ Sudah Ada (terverifikasi di kode)

| Modul | Bukti |
|-------|-------|
| Auth + PIN hierarki + clock-in device-gate | `features/auth/`, migrasi 065/066 |
| Self-order pelanggan via QR meja | `features/customer_menu/`, route `/menu/:tableToken` |
| POS cart + kategori + gambar menu | `features/pos/pos_page.dart`, `cart_panel.dart` |
| **Split payment** (bagi tagihan multi-metode) | `payment_page.dart:972` `_splits` |
| **Diskon manual + diskon loyalty** | `payment_page.dart:155`, `order.dart:120` |
| Promo + Loyalty (earn/redeem) | `features/settings/promo_page.dart`, migrasi 040–043 |
| Meja + status (available/occupied/reserved/dirty) | `table_select_page.dart`, `enums.dart` |
| Inventory/stok + expenses | `features/owner/inventory`, `expenses` |
| Refund + Void (+ alasan) | route `/owner/refund`, `/owner/void`, migrasi 067 |
| Shift buka/tutup + rekonsiliasi kas (expected vs actual) | `shift_page.dart`, `shift.dart` |
| Laporan penjualan + breakdown kategori + HPP | `/kasir/penjualan`, `/owner/breakdown`, migrasi 042 |
| **Offline queue + auto-sync saat online** | `offline_queue_service.dart`, `sync_service.dart` |
| Printer kasir/dapur + filter kategori + autoprint | `kitchen_print.dart`, `device_settings_page.dart` |
| Realtime notif order baru (web → auto-print) | `notification_service.dart`, migrasi 054 |

---

## ❌ Belum Ada / Perlu Dibuat (prioritas)

### 🔴 HIGH-1 — Kas Masuk/Keluar Selama Shift (Petty Cash / Paid-Out)
**Kondisi:** Shift hanya punya rekonsiliasi **buka & tutup** (`expected_cash` vs `actual_cash`). Tidak ada pencatatan pergerakan kas di tengah shift (ambil kembalian dari luar, bayar galon/ojek, setor sebagian ke owner).
**Dampak:** Selisih kas saat tutup shift tidak bisa dijelaskan → laporan kas tidak akurat, sulit audit.
**Rekomendasi:** Tabel `cash_movements` (shift_id, type `in`/`out`, amount, note, created_by) + UI tombol "Kas Masuk / Kas Keluar" di `shift_page.dart`. Sertakan di kalkulasi `expected_cash` saat tutup shift.
**Estimasi:** 1 tabel + 1 RPC + 1 sheet UI. ~M.

### 🔴 HIGH-2 — Keandalan Offline Sync (Head-of-Line Blocking + Scope Sempit)
**File:** `shared/services/sync_service.dart:37-40`
**Masalah:**
1. **Poison-message stall:** loop `break` pada kegagalan pertama. Satu entry yang selalu gagal (mis. order tertolak validasi server) **memblok seluruh antrean selamanya** — order valid di belakangnya tak pernah terkirim.
2. **Scope sempit:** hanya `pushOfflineOrder` yang di-queue. Penyesuaian stok, buka/tutup shift, refund/void **tidak** ter-queue → hilang saat offline.
3. Tidak ada batas retry / dead-letter / notifikasi ke kasir bila ada order gagal sync.
**Rekomendasi:**
- Bedakan **retryable** (network) vs **permanent** (validasi 4xx) → yang permanent dipindah ke dead-letter, jangan blok antrean.
- Tambah counter retry + badge "N transaksi belum tersinkron" di UI.
- Perluas queue ke operasi kritis lain (minimal: order + payment).
**Estimasi:** refactor `sync_service` + `offline_queue_service`. ~M.

### 🟡 MED-3 — Held / Parked Order (Simpan Sementara)
**Kondisi:** Tidak ada. Order non-meja (takeaway antre) tak bisa "ditahan" lalu dilanjut. (Open-bill via meja sudah ada sebagian.)
**Dampak:** Kasir tak bisa layani pelanggan B sambil pelanggan A masih memilih.
**Rekomendasi:** Simpan cart sebagai draft lokal + daftar "Order Ditahan" di POS. ~S.

### 🟡 MED-4 — Reservasi / Booking Meja
**Kondisi:** `reserved` cuma nilai enum `TableStatus`; tak ada flow booking (tanggal/jam/nama/DP).
**Rekomendasi:** Tabel `reservations` + kalender sederhana. Hanya jika klien butuh (fine-dining). ~M.

### 🟡 MED-5 — CRM Pelanggan
**Kondisi:** Hanya lookup loyalty by phone. Tak ada daftar pelanggan, riwayat kunjungan, atau profil.
**Rekomendasi:** Halaman "Pelanggan" (list + detail + histori order). Reuse data loyalty. ~M.

### 🟢 LOW-6 — Kirim Struk Digital (WhatsApp / Email)
**Kondisi:** Struk hanya via printer thermal.
**Rekomendasi:** Tombol "Kirim struk" → WA deeplink / share sheet (PDF/gambar struk). ~S.

### 🟢 LOW-7 — Scan Barcode Produk ke Cart (Retail Mode)
**Kondisi:** Jenis perangkat `scanner` ada di registry, tapi belum ada alur scan-barcode → tambah item ke cart (untuk retail/minimarket).
**Rekomendasi:** Verifikasi & wiring `scanner` ke input pencarian menu by SKU/barcode. ~S. (Skip bila murni F&B.)

### 🟢 LOW-8 — Kitchen Display System (KDS)
**Kondisi:** Akun dan layar khusus operator masak sengaja tidak digunakan.
Operasional produksi ditangani melalui tiket dan printer dapur dari aplikasi Kasir.

---

## Rekomendasi Urutan Eksekusi

| Prioritas | Fitur | Alasan |
|-----------|-------|--------|
| 1 | HIGH-2 Offline sync robustness | Risiko kehilangan transaksi = kehilangan uang |
| 2 | HIGH-1 Kas masuk/keluar shift | Akurasi kas harian, tuntutan operasional nyata |
| 3 | MED-3 Held order | UX kasir saat ramai |
| 4 | MED-5 CRM / LOW-6 Struk digital | Retensi pelanggan |
| 5 | MED-4 Reservasi / LOW-7 Barcode | Situasional per tipe bisnis |

**Catatan:** HIGH-2 juga muncul sebagai risiko keandalan; disarankan digabung dengan review menyeluruh alur offline sebelum deployment multi-device ke klien.

---
---

# Re-Audit — Round 2
**Tanggal:** 2026-07-05 (sesi lanjutan)

## Update status temuan Round 1
| ID R1 | Fitur | Status sekarang |
|-------|-------|-----------------|
| HIGH-2 | Keandalan offline sync | ✅ **SELESAI** — dead-letter + anti head-of-line blocking + 5 unit test (`offline_queue_test.dart`) |
| HIGH-1 | Kas masuk/keluar shift | ❌ Belum — masih hanya rekonsiliasi buka/tutup |
| MED-3 | Held/parked order | ❌ Belum (catatan: **open-bill** "Tambah ke Pesanan #" SUDAH ada — beda hal) |
| MED-4 | Reservasi meja | ❌ Belum |
| MED-5 | CRM pelanggan | ❌ Belum |
| LOW-6 | Struk digital (WA) | ❌ Belum |
| LOW-7 | Scan barcode retail | ❌ Belum |

## ✅ Terkonfirmasi SUDAH ADA (klarifikasi round ini)
- **Open bill** — tambah item ke order berjalan: `cart_panel.dart:368` ("Tambah ke Pesanan #") + cetak tiket dapur item baru (`kitchen_print.dart` `printKitchenTicketsForNewItems`).
- **Refund penuh** + alasan + otorisasi PIN (`order_list_page.dart` `_RefundButton`, migrasi 047/055/057).
- **Tampilan stok menipis** (pasif) — hitungan + status menipis/kritis/habis di owner dashboard & inventory.

## ❌ Gap BARU ditemukan (belum pernah dicatat)

### 🔴 NEW-1 — Transfer / Merge / Pindah Meja
**Kondisi:** Tidak ada. Tak bisa pindahkan order ke meja lain, atau gabung 2 bill jadi satu.
**Kenapa penting:** Realita dine-in — tamu pindah meja, atau 2 meja digabung saat bayar. Tanpa ini kasir harus batal + input ulang.
**Rekomendasi:** Aksi "Pindah Meja" (update `orders.table_id`) + "Gabung Bill" (merge order_items ke satu order). ~M.

### 🟡 NEW-2 — Refund Sebagian / Per-Item
**Kondisi:** Refund hanya **seluruh order** (status → cancelled). Tak bisa refund 1 item salah.
**Kenapa penting:** F&B sering: 1 dari 5 item salah/batal → sekarang harus refund semua lalu input ulang.
**Rekomendasi:** Refund pilih item + `refund_amount` parsial + catat di audit. Perlu kolom DB baru. ~M.

### 🟡 NEW-3 — Alert Stok Menipis (Proaktif)
**Kondisi:** Stok menipis hanya **ditampilkan pasif** (badge/hitungan) di dashboard owner. Tak ada notifikasi dorong saat stok mencapai `min_stock_qty`.
**Rekomendasi:** Notifikasi (realtime/local) saat `stock_qty <= min_stock_qty` sesudah transaksi. Reuse `NotificationService`. ~S.

### 🟢 NEW-4 — Purchase Order / Stok Masuk (Supplier)
**Kondisi:** Stok hanya via `adjust_stock` manual. Tak ada alur pembelian: supplier, PO, terima barang, harga beli.
**Kenapa penting:** HPP akurat butuh pencatatan pembelian, bukan koreksi manual.
**Rekomendasi:** Tabel `suppliers` + `purchase_orders` + alur terima → auto tambah stok + update cost. ~L. (Situasional.)

### 🟢 NEW-5 — Tips / Gratuity
**Kondisi:** Tidak ada field tip. (Mungkin tak relevan untuk F&B lokal — LOW.)

## Prioritas gabungan (setelah HIGH-2 selesai)
| Prioritas | Fitur | Alasan |
|-----------|-------|--------|
| 1 | HIGH-1 Kas masuk/keluar | Akurasi kas harian (carry-over) |
| 2 | NEW-1 Transfer/merge meja | Realita dine-in harian |
| 3 | NEW-2 Refund sebagian | Kesalahan per-item umum di F&B |
| 4 | NEW-3 Alert stok proaktif | Cegah kehabisan bahan |
| 5 | MED-3/5, NEW-4 | Held order, CRM, PO — situasional |

---
---

# Re-Audit — Round 3: Robustness & Kesiapan Produksi
**Tanggal:** 2026-07-05 (audit lebih dalam)
**Fokus:** bukan wishlist fitur — tapi ketahanan alur yang SUDAH ada saat dipakai klien multi-device.

## ✅ Kontrol positif terverifikasi
- **Guard double-tap** di tombol bayar (`payment_page.dart` `_busy`) → tak bisa dobel-charge dari UI.
- **Idempotensi pembayaran** di backend (migrasi 034).
- **Reprint** struk untuk order lunas tersedia.
- Mata uang lewat formatter (konsisten; sedikit literal 'Rp 0' tak berbahaya).

## ❌ Gap robustness (belum pernah dicatat)

### 🔴 R3-1 — Tidak Ada Crash Reporting / Telemetri
**Kondisi:** Tak ada Sentry/Crashlytics (`pubspec.yaml` bersih). Aplikasi jalan di tablet klien tanpa **visibilitas apa pun** saat crash/error di lapangan.
**Dampak:** Kalau kasir klien mengalami crash, tim dev tak pernah tahu. Buta total di produksi.
**Rekomendasi:** Integrasikan Sentry Flutter (gratis tier cukup) → tangkap crash + stack trace + device info. ~S.

### 🔴 R3-2 — Tidak Ada Global Error Handler
**File:** `lib/main.dart` — `void main()` polos, tanpa `runZonedGuarded` / `FlutterError.onError`.
**Dampak:** Error async tak tertangkap **hilang diam-diam** (atau bikin layar merah di debug). Dipadukan R3-1 = nol jejak.
**Rekomendasi:** Bungkus `runApp` dengan `runZonedGuarded` + set `FlutterError.onError` → teruskan ke logger/Sentry. ~XS.

### 🟡 R3-3 — Kegagalan Cetak Struk Ditelan Diam-Diam
**File:** `lib/features/pos/presentation/pages/payment_page.dart:761-769`
```dart
await printer.printReceiptBytes(bytes);   // return bool DIABAIKAN
...
} catch (_) { /* swallow — printer best-effort */ }
```
**Dampak:** Bila printer mati/putus, struk gagal cetak TANPA sinyal ke kasir. Kasir tak sadar perlu cetak ulang → pelanggan tak dapat struk. "Best-effort" boleh, tapi **harus ada notifikasi**.
**Rekomendasi:** Cek hasil `printReceiptBytes`; bila gagal tampilkan toast "Struk gagal dicetak — cetak ulang?" + shortcut reprint. ~XS. **(Paling cepat difix, dampak nyata.)**

### 🟡 R3-4 — Tidak Ada Force-Update / Version Gate
**Kondisi:** Tak ada pengecekan versi minimum. Saat rilis fix kritis (mis. bug pajak), device klien lama tetap jalan versi cacat.
**Rekomendasi:** Cek `min_version` (dari tabel outlet settings / remote config) saat start → paksa update bila di bawah minimum. ~S.

### 🟢 R3-5 — Coverage Uji Perhitungan Uang Tipis
**Kondisi:** `pos_bloc_test` menguji subtotal & qty, TAPI tak ada assert eksplisit untuk pipeline penuh: subtotal → diskon → **pajak + service charge** → total, dan **kembalian** (cash change).
**Dampak:** Regresi di rumus pajak/service/kembalian bisa lolos tes. Untuk app uang, ini risiko.
**Rekomendasi:** Tambah unit test: kombinasi diskon+pajak+service → total, dan hitung kembalian. ~S.

### 🟢 R3-6 — Tak Ada Clamp Text-Scale (Aksesibilitas)
**Kondisi:** Tak ada `textScaler` clamp. Bila font sistem device diset besar, layout tinggi-tetap (`mainAxisExtent: 205`, kartu tinggi fixed) bisa overflow.
**Rekomendasi:** Clamp `MediaQuery.textScaler` di root (mis. 0.9–1.2) untuk device POS. ~XS.

## Prioritas Round 3
| # | Temuan | Effort | Kenapa dulu |
|---|--------|--------|-------------|
| 1 | R3-3 Notif cetak gagal | XS | Dampak operasional langsung, cepat |
| 2 | R3-2 Global error handler | XS | Fondasi visibilitas |
| 3 | R3-1 Crash reporting (Sentry) | S | Mata di produksi klien |
| 4 | R3-5 Test money-math | S | Lindungi rumus uang |
| 5 | R3-4 Force-update | S | Kontrol rilis multi-device |
| 6 | R3-6 Clamp text-scale | XS | Cegah overflow |

**Catatan:** R3-1/R3-2/R3-3 adalah **kesiapan produksi** — sebaiknya kelar SEBELUM rollout luas ke banyak device klien, supaya masalah lapangan terlihat & tertangani.

---

## Round 3 (lanjutan) — hasil probe lebih dalam

### ✅ Fix diterapkan
- **R3-3 SELESAI** — `payment_page.dart` `_tryPrintWalkinReceipt`: hasil `printReceiptBytes` kini dicek; gagal → toast "Struk gagal dicetak. Buka order → cetak ulang." + tidak menandai "sudah dicetak" bila gagal (agar reprint tak terblok batas cetak). `catch` juga memberi notif, bukan swallow diam. Analyze bersih, 101 test lulus.

### ✅ Terverifikasi AMAN (bukan gap)
- **Resource dispose seimbang** (21 `dispose()` vs 20 file pembuat controller) → tak ada leak sistemik.
- **NotificationService** punya `stop()` + unsubscribe channel lama → lifecycle realtime bersih.
- **QR self-order** menangani token invalid ("Meja tidak ditemukan atau tidak aktif").
- **Guard perhitungan uang**: `(subtotal − diskon − loyalty).clamp(0, ∞)` & `_remaining.clamp(0, ∞)` → total tak pernah negatif.

### ❌ Gap BARU
### 🟡 R3-7 — Timezone WIB Hardcode (Tak Ada TZ per-Outlet)
**Kondisi:** `outlets` tak punya kolom timezone. `Asia/Jakarta`/`toLocal()`/`DateTime.now()` tersebar di banyak file POS/orders (dan di migrasi retensi 084/086 yang baru).
**Dampak:** Outlet di zona **WITA/WIT** (Bali, Makassar, Papua = UTC+8/+9) → batas hari laporan & shift meleset 1–2 jam → penjualan bisa masuk tanggal yang salah.
**Kenapa mungkin OK sekarang:** bila semua outlet klien di Jawa (WIB), tak berdampak. Tapi laten untuk ekspansi multi-region.
**Rekomendasi:** Tambah `outlets.timezone` (default `'Asia/Jakarta'`), pakai di perhitungan batas-hari (app + rollup migrasi). ~M. (Situasional — hanya bila ada outlet luar WIB.)

---
---

# Re-Audit — Round 4: Owner-Panel (Web) & Integrasi Data
**Tanggal:** 2026-07-05

## ✅ Gap dikerjakan turn ini
- **NEW-1 Pindah/Gabung Meja SELESAI** — migrasi 089 (trigger sync_table_status handle pindah meja + RPC `merge_orders`), datasource `transferTable`/`mergeOrders`, UI "Pindah Meja" + "Gabung" di detail order dine-in. Analyze bersih, 106 test lulus.
- **HIGH-1 Kas Masuk/Keluar SELESAI** (turn sebelumnya) — migrasi 088.

## Owner-panel (web) — sudah sangat lengkap (38 halaman)
Menu, kategori, extras, departemen, expenses, loyalty, order, pembayaran, print station, promo, QR, struk, refund/void report, sales summary/breakdown, shift list, staff, stok + laporan stok, meja, pajak; + owner: branch monitoring, finance, staff, drill-down (top produk, per kasir, per kategori, metode bayar, performa outlet).

## ❌ Gap integrasi BARU (data mobile ↔ web)

### 🟡 R4-1 — Kas Masuk/Keluar Tak Tampil di Web
**Kondisi:** Fitur baru `cash_movements` (mobile) tak dirender di owner-panel. `ShiftList.tsx` tampilkan kas buka/tutup/expected/selisih tapi **tak ada rincian pergerakan kas** per shift. Owner tak bisa audit "kas keluar buat apa saja".
**Rekomendasi:** Di detail shift `ShiftList.tsx`, tarik `cash_movements` (by shift_id) → tampilkan daftar in/out + net. ~S.

### 🟡 R4-2 — Rollup `sales_daily_summary` Belum Dikonsumsi
**Kondisi:** Migrasi 084 membuat tabel rollup + backfill + refresh nightly, tapi laporan web/mobile masih query **raw `orders`**.
**Dampak:** (a) laporan periode panjang tetap berat; (b) **arsip cold (086) TAK AMAN dijalankan** sampai laporan historis baca dari rollup.
**Rekomendasi:** Arahkan laporan periode > 60 hari ke `sales_daily_summary`. **Prasyarat sebelum 086.** ~M.

### 🟢 R4-3 — Merge/Transfer Perlu Verifikasi Staging
**Kondisi:** Migrasi 089 (RPC merge_orders + trigger) tak bisa diuji lokal (tanpa Postgres). Logika sudah direview manual (money kekal, stok pindah, void sumber no-op restore).
**Rekomendasi:** Uji di Supabase staging: (1) pindah meja bebaskan meja lama, (2) gabung 2 bill → total = jumlah, stok tak double, meja sumber bebas.

## Status keseluruhan gap (kumulatif)
| Gap | Status |
|-----|--------|
| HIGH-2 Offline sync | ✅ Selesai |
| HIGH-1 Kas masuk/keluar | ✅ Selesai (mobile) |
| NEW-1 Pindah/Gabung meja | ✅ Selesai (perlu verif staging) |
| R3-3 Notif cetak gagal | ✅ Selesai |
| NEW-2 Refund sebagian | ❌ Terbuka |
| NEW-3 Alert stok proaktif | ❌ Terbuka |
| R3-1/R3-2 Crash reporting + error handler | ❌ Terbuka |
| R4-1 Kas di web | ❌ Terbuka |
| R4-2 Konsumsi rollup | ❌ Terbuka (prasyarat 086) |

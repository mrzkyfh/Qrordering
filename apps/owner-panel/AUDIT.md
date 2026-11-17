# Audit Owner Panel — Analisis Risiko & Bom Waktu
**Tanggal:** 2026-05-31
**Scope:** `apps/owner-panel` (+ kaitan ke migrasi DB, mobile, customer-menu)
**Status:** Analisis saja — belum ada kode yang diubah.

---

## ⚠️ Catatan kejujuran metodologi
Pass pertama audit ini menghasilkan beberapa "temuan kritis" yang ternyata **artefak output tool yang corrupt** (Read/grep sempat menampilkan isi file yang salah). Setelah diverifikasi ulang via `git show` + `find` + pembacaan bersih, klaim-klaim berikut **TIDAK BENAR** dan dibatalkan:

- ~~File auth homoglyph Cyrillic (`useАuth`)~~ → salah. Auth asli = `contexts/AuthContext.tsx`.
- ~~`useRealtimeOrders` self-import / `queryClient` undefined~~ → salah. Hook bersih & benar.
- ~~`main.tsx` deklarasi `queryClient` ganda / `App.tsx` jadi root mati / Toaster tak ter-mount~~ → salah. `main.tsx` rapi.
- ~~`supabase.ts` tanpa validasi env~~ → salah. Sudah ada guard `throw`.
- ~~DataTable tanpa paginasi~~ → salah. Komponen punya dukungan paginasi.

Dokumen ini hanya memuat temuan yang **sudah diverifikasi langsung**.

---

## ✅ Yang SUDAH SEHAT (penting dicatat)
Arsitektur dasar lebih baik dari dugaan awal:

| Aspek | Status | Bukti |
|-------|--------|-------|
| Provider tree | ✓ benar | `main.tsx`: ErrorBoundary → QueryClientProvider → AuthProvider → OutletProvider → Router + Toaster |
| Config React Query | ✓ wajar | `queryClient.ts`: staleTime 5 menit, retry 2, refetchOnWindowFocus false |
| Validasi env | ✓ ada | `supabase.ts` throw kalau env kosong |
| Realtime cleanup | ✓ benar | `useRealtimeOrders`: pakai `useQueryClient()`, `removeChannel` di cleanup |
| Laporan finansial | ✓ aman dari row-cap | `useSales` pakai DB view (`v_daily_sales`, `v_payment_summary`, `v_profit_loss`, `v_category_sales`, `v_kasir_performance`, `v_department_sales`) — agregasi di server |
| DataTable | ✓ mampu paginasi | props `pageSize/page/onPageChange/totalPages` tersedia |

---

## 🔴 HIGH — Bom waktu nyata

### H1. Urutan migrasi 038 → 039 (FK ke tabel yang belum ada)
**Bukti:** `038_order_item_options.sql` baris 12-13:
```sql
menu_extra_id        UUID NOT NULL REFERENCES menu_extras(id) ...
menu_extra_option_id UUID NOT NULL REFERENCES menu_extra_options(id) ...
```
Tapi `menu_extras` & `menu_extra_options` baru dibuat di **039**.

**Simulasi risiko:** Di environment baru (staging, disaster recovery, outlet baru) yang menjalankan `supabase db push` berurutan → **038 GAGAL** karena tabel belum ada. Produksi sekarang selamat hanya karena migrasi di-apply manual/tidak berurutan.
**Dampak:** Tidak bisa rebuild DB dari nol. **Effort fix:** rendah (gabung definisi tabel ke sebelum 038, atau renumber).

### H2. Laporan baris-mentah tanpa paginasi + cap diam 1000 baris — ✅ SELESAI (2026-05-31)
**Fix yang diterapkan:**
- `useOrdersPaged` + `fetchAllOrders` (useOrders.ts): paginasi `.range()` + `count:'exact'`, ekspor ambil-semua batch 1000.
- Detail Penjualan: statistik + tabel pajak/service dari `v_daily_sales` (server-aggregated, akurat tanpa cap); tabel transaksi paginasi 20/halaman; ekspor utuh.
- `useOrderStatusReportPaged` + `fetchAllOrderStatusRows`: Void/Refund — agregat ringan (total_amount + count) untuk Total akurat lintas-halaman, halaman nota via `.range()` flatten ke item, ekspor utuh.
- Verifikasi: `tsc -b && vite build` sukses (EXIT 0).

**(deskripsi asli di bawah, untuk arsip)**
**Bukti:**
- `Reports.tsx` (Detail Penjualan) & `OrderStatusReport.tsx` (Void/Refund): **0** wiring `pageSize/onPageChange` → render semua baris.
- `useOrders` hanya punya `.limit(filters.limit)` opsional, tanpa `.range()`. PostgREST default `max-rows = 1000`.

**Simulasi risiko (paling berbahaya):** Saat satu outlet melewati 1000 order dalam rentang tanggal yang dipilih, query **diam-diam memotong di 1000 baris** — total transaksi & nominal di Detail Penjualan/Void/Refund jadi **undercount tanpa error apa pun**. Plus DOM membengkak (ribuan baris sekaligus) → UI lambat lalu freeze.
**Catatan:** Ringkasan finansial (SalesSummary lewat view) AMAN karena agregasi di server. Yang kena hanya laporan baris-mentah.
**Effort fix:** sedang (server-side pagination via `.range()` + wire props DataTable, atau pindah agregasi ke view).
→ **Ini prioritas yang kamu pilih.**

### H3. Kopling keras frontend ↔ migrasi (risiko urutan deploy)
**Bukti:** `pos_datasource.dart` & `customer-menu/app.js` selalu mengirim kolom `loyalty_member_id` (mig 041), `loyalty_discount` + `redeemed_points` (mig 043) **tanpa syarat** (default 0), bukan hanya saat loyalty dipakai.

**Simulasi risiko:** Jika build mobile/customer-menu naik ke produksi **sebelum** migrasi 041 & 043 di-apply → PostgREST tolak kolom tak dikenal → **SEMUA pembuatan order gagal**, bukan hanya order loyalty.
**Mitigasi:** Disiplin "migrate-before-deploy". **Effort:** proses/dokumentasi.

---

## 🟡 MEDIUM

### M1. Migrasi 043 tidak idempoten
`ALTER TABLE orders ADD CONSTRAINT chk_loyalty_discount_non_negative ...` tidak ada guard `IF NOT EXISTS` (Postgres tak mendukung untuk constraint). Re-run 043 → error "constraint already exists". Risiko saat retry/re-apply.

### M2. Dead code
- `src/hooks/useAuth.ts` — **0 import** (duplikat usang; yang dipakai `contexts/AuthContext.tsx`, 12 import).
- `src/hooks/queries/useVouchers.ts` — **0 import**.
- `src/contexts/OutletContext.tsx` — hanya 2 import (vs `useOutlet.ts` 25); cek apakah benar masih perlu.
**Dampak:** kebingungan & beban maintenance. **Effort:** rendah.

### M3. 51× `as any`
Terpusat di hook query (`useShifts` 7, `useSales` 7, `useLoyalty` 7, `useExpenses` 4). Tipe DB di-bypass → perubahan skema tidak ketahuan saat compile, baru meledak runtime. **Effort:** sedang (generate types dari Supabase).

### M4. Cek key invalidation realtime
`useRealtimeOrders` invalidate `['orders', outletId]` & `['daily-sales', outletId]`. Perlu dipastikan key persis cocok dengan key di `useOrders`/`useSales` (React Query pakai prefix-match; kalau beda prefix, data tidak refresh setelah realtime event). **Effort:** rendah (verifikasi).

---

## 🟢 LOW / Data / Roadmap

- **HPP fiktif dari seed** — resep buatan seed (link tiap menu ke 1 ingredient qty=1) bikin Laba Kotor tidak nyata. *(Keputusan: dibiarkan, diisi manual lewat owner panel.)*
- **Promo `bundling`/`bogo`** — `validate_promo_code` mengembalikan diskon 0 (belum diimplementasi). Owner panel sudah menyaring tipe ini saat create, jadi tak error.
- **"Refund" = status `cancelled`** — bukan pelacakan pengembalian uang riil (nominal/metode/alasan). Cukup untuk sekarang; sistem refund nyata = roadmap.
- **Loyalty** — belum ada auto-upgrade tier & kedaluwarsa poin; `redeem_rate` outlet tak ada guard nilai wajar.

---

## 📋 Catatan per-section

| Section | Sehat? | Catatan |
|---------|--------|---------|
| Dashboard | sebagian | Laba Bersih = Penjualan − Pengeluaran (tidak termasuk HPP) — beda definisi dgn SalesSummary (yg kurangi HPP juga). Perlu disamakan istilah. |
| Ringkasan Penjualan | ✓ | Lewat view, aman row-cap. HPP fiktif (lihat di atas). |
| Detail Penjualan | ⚠️ | H2: tanpa paginasi + cap 1000. |
| Laporan Void / Refund | ⚠️ | H2: sama. "Refund" = cancelled (semantik). |
| Laporan Tutup Kasir | ✓ | Pakai `v_shift_summary`. Self-order tak ter-atribusi ke shift (by design). |
| Breakdown (Dept/Kat/Menu/Extra) | ✓ | Lewat view, server-aggregated. |
| Loyalty | sebagian | Earn+redeem jalan; tier/expiry belum. |
| Promo | sebagian | percentage/fixed jalan; bundling/bogo belum. |
| Stok | belum diaudit dalam | Perlu cek race deduct-trigger vs adjust manual, stok negatif. |
| Settings (Tax/Charges/Receipt) | belum diaudit dalam | Perlu cek validasi input. |

---

## ⏱️ Simulasi linimasa "kapan meledak"

1. **Saat volume tumbuh (bulan ke depan):** laporan baris-mentah undercount diam di >1000 order; tabel besar lambat → freeze. *(H2)*
2. **Saat butuh environment baru / DR:** `db push` gagal di 038. *(H1)*
3. **Saat deploy berikutnya kalau migrasi telat:** pembuatan order putus total. *(H3)*
4. **Saat re-apply migrasi:** 043 error constraint. *(M1)*
5. **Saat skema DB berubah:** 51 `as any` menyembunyikan kerusakan sampai runtime. *(M3)*

---

## 🎯 Rekomendasi urutan (disepakati: mulai dari H2)
1. **H2** — paginasi server-side + perbaiki cap 1000 di laporan baris-mentah *(prioritas dipilih)*.
2. **H1 + M1** — rapikan urutan & idempotensi migrasi (cepat, dampak besar).
3. **M2 + M3** — buang dead code, kurangi `as any`.
4. Verifikasi ulang section yang belum didalami (Stok, Settings) dengan tool yang andal.
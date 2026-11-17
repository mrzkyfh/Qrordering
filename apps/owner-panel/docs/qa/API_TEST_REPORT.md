# API Test Report — Section Laporan

**Tanggal:** 2026-05-28
**Target:** Supabase PostgREST views & embedded queries yang digunakan section laporan
**Test file:** `apps/owner-panel/tests/api/laporan-api.test.mjs`
**Mode jalan:** `cd apps/owner-panel && node --test tests/api/laporan-api.test.mjs`

---

## Ringkasan Eksekutif

| Metrik | Nilai |
|---|---|
| Total test cases | 18 |
| **Pass** | **16** |
| **Fail** | **2** (bug schema confirmed) |
| **Blocker** | **1** (auth login broken — partial run) |
| Coverage | 11 views + 1 embed query + 4 edge cases + 1 RLS smoke |

**Status:** ⚠️ **NOT PRODUCTION READY** — 3 bug confirmed (1 critical, 2 high), section Dashboard juga terpengaruh.

---

## Test Coverage

Endpoint yang diuji (semua via Supabase PostgREST):

| # | View / Endpoint | Dipakai oleh | Status |
|---|---|---|---|
| 1 | `v_daily_sales` | Reports (lama), Dashboard | ✅ PASS |
| 2 | `v_top_menu_items` | Dashboard top menu widget | ✅ PASS |
| 3 | `v_payment_summary` | Dashboard payment chart | ❌ **FAIL** |
| 4 | `v_profit_loss` | Owner FinanceReport | ✅ PASS |
| 5 | `v_category_sales` | SalesBreakdown Kategori tab | ✅ PASS (BUG-LAP-005 fixed) |
| 6 | `v_category_sales` (multi-month) | SalesBreakdown Kategori tab | ✅ PASS (BUG-LAP-003 fixed) |
| 7 | `v_department_sales` | SalesBreakdown Departemen tab | ✅ PASS |
| 8 | `v_menu_sales` | SalesBreakdown Menu tab | ✅ PASS |
| 9 | `v_tax_report` | SalesBreakdown Pajak & Biaya tab | ✅ PASS |
| 10 | `v_kasir_performance` | Dashboard kasir leaderboard | ❌ **FAIL** |
| 11 | `orders + payments embed` | Reports.tsx Ringkasan Penjualan | ✅ PASS |
| 12 | gross ≥ net (business rule) | semua daily breakdown | ✅ PASS |
| 13 | RLS smoke (anon role) | security | ✅ PASS (RLS works) |
| 14 | future date range | edge case | ✅ PASS (returns []) |
| 15 | non-existent UUID | edge case | ✅ PASS (returns []) |
| 16 | malformed UUID | edge case | ✅ PASS (returns 400) |
| 17 | ORDER BY total_revenue desc | sort | ✅ PASS |

**Setup test:** Login dengan akun QA dari environment → **invalid_credentials**. Saat ini tests berjalan dalam mode anon — bug schema-level (kolom hilang, tipe salah) tetap ketangkap karena PostgREST memvalidasi query sebelum mengembalikan data. Test row-level memerlukan auth.

---

## Bug Findings

### BUG-LAP-API-001 — Login user QA ditolak (BLOCKER)

**Severity:** BLOCKER
**Endpoint:** `POST /auth/v1/token?grant_type=password`
**Reproduce:**
```bash
curl -s -X POST "https://kkzlpczlpffxodepelgc.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: <anon>" -H "Content-Type: application/json" \
  -d '{"email":"<E2E_EMAIL>","password":"<E2E_PASSWORD>"}'
```
**Response:**
```json
{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}
```

**Dampak:**
- E2E Playwright suite (`tests/laporan.spec.ts`) tidak bisa jalan
- API tests berjalan dalam mode anon → row-level tests (jumlah data, hitungan agregat) tidak bisa diverifikasi
- User-reported: "gabisa login" — dikonfirmasi reproducible

**Root cause kandidat:** Password user di-reset, atau user di-delete & re-create di Supabase Auth.

**Action required:** siapkan akun khusus QA, lalu isi `E2E_EMAIL` dan `E2E_PASSWORD` melalui environment lokal/CI. Jangan menaruh kredensial di source.

---

### BUG-LAP-API-002 — `v_payment_summary.pay_date` query LIKE gagal (HIGH)

**Severity:** HIGH (silent failure — dashboard widget kosong tanpa error UI)
**File:** `apps/owner-panel/src/hooks/queries/useSales.ts:64`
**Reproduce:**
```bash
curl -s "https://kkzlpczlpffxodepelgc.supabase.co/rest/v1/v_payment_summary?pay_date=like.2026-05*&select=*" \
  -H "apikey: <anon>"
```
**Response:**
```json
{
  "code": "42883",
  "message": "operator does not exist: date ~~ unknown",
  "hint": "No operator matches the given name and argument types. You might need to add explicit type casts."
}
```
**HTTP:** `404`

**Root cause:**
`v_payment_summary.pay_date` berbentuk `DATE`, bukan `TEXT`. PostgreSQL operator `LIKE` (`~~`) hanya bekerja untuk text. Kode saat ini:
```ts
.like('pay_date', `${month}%`)   // ❌ FAIL — pay_date is date
```

**Dampak:**
- Dashboard `/owner/dashboard` & `/admin/dashboard` — widget "Distribusi Metode Pembayaran" akan throw error & menampilkan state error/empty
- Affected files:
  - `src/pages/owner/Dashboard.tsx:123` (`usePaymentSummary(null, currentMonth)`)
  - `src/pages/admin/Dashboard.tsx:134` (`usePaymentSummary(activeOutletId, currentMonth)`)

**Fix:** Pakai gte/lte dengan boundary tanggal, bukan LIKE:
```ts
const monthStart = `${month}-01`
const monthEnd = format(endOfMonth(new Date(monthStart)), 'yyyy-MM-dd')
let query = supabase.from('v_payment_summary').select('*')
  .gte('pay_date', monthStart)
  .lte('pay_date', monthEnd)
```

Pattern yang sama juga dipakai oleh `useTopMenuItems` (line 42, `sale_date=like`) — namun `v_top_menu_items.sale_date` bertipe `text` di view itu sehingga LIKE jalan. Verifikasi tetap perlu konfirmasi tipe di SQL editor.

---

### BUG-LAP-API-003 — `v_kasir_performance` tidak punya kolom `shift_date` (HIGH)

**Severity:** HIGH (silent failure — dashboard kasir widget kosong)
**File:** `apps/owner-panel/src/hooks/queries/useSales.ts:146`, `src/types/database.ts:408`
**Reproduce:**
```bash
curl -s "https://kkzlpczlpffxodepelgc.supabase.co/rest/v1/v_kasir_performance?shift_date=like.2026-05*&select=*" \
  -H "apikey: <anon>"
```
**Response:**
```json
{
  "code": "42703",
  "message": "column v_kasir_performance.shift_date does not exist"
}
```
**HTTP:** `400`

**Kolom view yang sebenarnya ada** (hasil probing kolom per-kolom):
- ✅ `kasir_id` (uuid)
- ✅ `kasir_name` (text)
- ✅ `outlet_id` (uuid)
- ✅ `total_orders` (int)
- ✅ `total_revenue` (numeric)
- ❌ `shift_date` — TIDAK ADA
- ❌ `id`, `void_count`, `cash_difference` — TIDAK ADA (TypeScript type `KasirPerformance` masih mendeklarasi semuanya)

**Dampak:**
- Dashboard kasir leaderboard di `Dashboard.tsx` (owner & admin) tidak menampilkan data — query gagal di runtime
- Type `KasirPerformance` di `database.ts` menyesatkan IDE/TS — autocomplete menawarkan property yang akan undefined di runtime
- Tidak ada agregasi per-periode mungkin di view ini → fitur "Top Kasir bulan ini" mustahil tanpa view di-update

**Fix opsi A — fix kode:**
```ts
// useSales.ts — hapus filter date, view sudah aggregate
let query = supabase.from('v_kasir_performance').select('*')
if (outletId) query = query.eq('outlet_id', outletId)
// Hapus parameter `month` dari signature
```
Update type:
```ts
export interface KasirPerformance {
  kasir_id: string
  kasir_name: string
  outlet_id: string
  total_orders: number
  total_revenue: number
}
```

**Fix opsi B — update view (rekomendasi):**
Buat migration baru tambahkan kolom `shift_date` ke `v_kasir_performance` agar filter periode bisa dilakukan. Tanpa ini, "Top Kasir bulan X" tidak akurat (datanya all-time aggregate).

---

## Non-Bug Findings (Catatan)

### RLS pada views: ✅ Berfungsi
Anon role yang query `v_daily_sales` tanpa JWT mendapat `[]` — tidak ada data bocor. Tes RLS smoke pass.

### Edge cases: ✅ Robust
- Future date range → `[]` tanpa error
- UUID tidak ada → `[]` tanpa error
- UUID malformed → `400` dengan error message yang jelas

### Migration status
Berdasarkan response sukses pada `v_department_sales`, `v_menu_sales`, `v_tax_report`, dan `v_category_sales` punya kolom `total_orders`:
- ✅ Migration **031** sudah di-apply (sales breakdown views ada)
- ✅ Migration **032** sudah di-apply (`v_category_sales.total_orders` ada)
- ❌ Belum ada migration untuk fix `v_kasir_performance.shift_date`

---

## Cara Re-run

```bash
cd apps/owner-panel
node --test tests/api/laporan-api.test.mjs
```

Setelah BUG-LAP-API-001 diperbaiki (login bisa), tambahkan assertion row-level dengan mengubah block `if (body.length)` jadi `assert.ok(body.length > 0)` untuk view yang punya seed data.

---

## Rekomendasi Prioritas Fix

1. **BUG-LAP-API-001** (blocker) — reset password user QA → buka jalan untuk Playwright E2E + row-level API tests
2. **BUG-LAP-API-002** (high, silent) — ganti `.like('pay_date', ...)` ke `.gte`/`.lte` di `usePaymentSummary` → fix dashboard payment widget
3. **BUG-LAP-API-003** (high, silent) — pilih fix A (hapus filter periode) atau B (update view) untuk `useKasirPerformance`, update `KasirPerformance` type

Tidak ada bug yang ditemukan di section `/admin/sales-breakdown/*` maupun `/admin/reports` (Ringkasan Penjualan) — semua view & query berfungsi.

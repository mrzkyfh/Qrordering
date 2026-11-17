# Bug Report — Section Laporan (2026-05-28)

---

## BUG-LAP-001 — CurrencyDisplay prop salah: `amount` bukan `value`

**Severity:** HIGH  
**Status:** FIXED  
**File:** `src/pages/admin/SalesBreakdownReport.tsx`

**Deskripsi:**  
Komponen `CurrencyDisplay` menggunakan prop `value` (lihat `src/components/ui/CurrencyDisplay.tsx`), tapi semua 17 penggunaan di `SalesBreakdownReport.tsx` memakai prop `amount`. Karena TypeScript tidak strict (tidak ada `strict: true` di tsconfig), error ini tidak terdeteksi saat compile.

**Dampak:**  
Semua nilai currency di halaman Laporan Penjualan (Departemen, Kategori, Menu, Pajak) menampilkan `Rp0` meskipun data ada.

**Root Cause:**  
`tsconfig.app.json` tidak punya `"strict": true`. TypeScript dalam mode non-strict tidak cek excess/wrong props pada JSX.

**Fix:**  
Ganti semua `<CurrencyDisplay amount={x} />` → `<CurrencyDisplay value={x} />` di `SalesBreakdownReport.tsx`.

**Test Regresi:**  
`tests/laporan.spec.ts` → describe `"Regresi — currency values tidak Rp0"`

---

## BUG-LAP-002 — `Receipt` icon dipakai tapi tidak diimport setelah refactor

**Severity:** LOW (runtime crash di render)  
**Status:** FIXED  
**File:** `src/pages/admin/SalesBreakdownReport.tsx`

**Deskripsi:**  
Saat menghapus import tab-terkait (`Building2`, `Tag`, `UtensilsCrossed`, `Package`, `Receipt`) waktu refactor ke route-based tabs, icon `Receipt` dipakai di komponen `Empty()` tapi tidak diimport ulang.

**Fix:**  
Tambah `Receipt` kembali ke import `lucide-react`.

---

## BUG-LAP-003 — `KategoriTab` hanya fetch data bulan pertama dari range multi-bulan

**Severity:** MEDIUM  
**Status:** FIXED  
**File:** `src/hooks/queries/useSales.ts`, `src/pages/admin/SalesBreakdownReport.tsx`

**Deskripsi:**  
Hook `useCategorySales` menggunakan `month` (7 karakter dari `dateFrom`, contoh `"2026-05"`) sebagai filter `.like('sale_date', '2026-05%')`. Jika user memilih date range yang mencakup 2 bulan (mis. 15 Mei – 15 Juni), hanya data Mei yang di-fetch. Data Juni tidak diambil.

**Dampak:**  
Tab Kategori tidak akurat untuk date range lintas bulan.

**Fix:**  
Tambah hook `useCategorySalesRange(outletId, dateFrom, dateTo)` menggunakan `.gte()` + `.lte()`. `KategoriTab` sekarang pakai hook baru ini — tidak ada lagi client-side date filter.

---

## BUG-LAP-005 — `KategoriTab` crash: `d.orders.toLocaleString` undefined

**Severity:** HIGH (crash — white screen)
**Status:** FIXED
**File:** `src/types/database.ts`, `src/pages/admin/SalesBreakdownReport.tsx`

**Deskripsi:**
`v_category_sales` (migration 015) tidak punya kolom `total_orders`. Type `CategorySales` salah mencantumkan `total_orders: number` dan tidak mencantumkan `qty_sold`. Akibatnya `r.total_orders` selalu `undefined` → crash saat `.toLocaleString()`.

**Fix:**
1. Update `CategorySales` type: tambah `qty_sold: number`, ubah `total_orders` jadi `number | null`
2. `KategoriTab`: pakai `r.qty_sold ?? 0` dan `r.total_orders ?? 0` (defensive)
3. Migration `032_category_sales_add_total_orders.sql`: update view tambah `COUNT(DISTINCT o.id) AS total_orders`

**Action Required:**
Jalankan `032_category_sales_add_total_orders.sql` di Supabase SQL Editor agar kolom `total_orders` ada di view.

---

## BUG-LAP-004 — Views `v_department_sales`, `v_menu_sales`, `v_tax_report` belum ada sampai migration 031 dijalankan

**Severity:** HIGH (fitur tidak berfungsi sama sekali)
**Status:** ✅ RESOLVED (migration 031 + 032 sudah dijalankan, API test 18/18 PASS — TEST_EXECUTION_REPORT.md)

**Deskripsi:**
Migration `031_sales_breakdown_views.sql` perlu dijalankan manual di Supabase SQL Editor. Sampai migration ini jalan, semua tab di `/admin/sales-breakdown/*` akan menampilkan state kosong (Empty) tanpa error eksplisit.

**Action Required:**
✅ Sudah dilakukan — verifikasi: `tests/api/laporan-api.test.mjs` mengakses semua view (v_department_sales, v_menu_sales, v_tax_report) dan 18/18 test PASS.

---

## BUG-XCC-001 — Outlets RLS anon leak (loyalty_settings + payment_methods)

**Severity:** MEDIUM
**Status:** ✅ RESOLVED (migration 033 sudah dijalankan 2026-05-28, verifikasi pass: anon SELECT * → 401, view publik 200)
**File:** `apps/supabase/migrations/033_outlets_anon_field_security.sql`, `apps/mobile/time420s/lib/features/customer_menu/presentation/pages/customer_menu_page.dart`

**Deskripsi:**
Policy `outlets_select_anon` di migration `008_customer_menu_anon.sql` memberi anon SELECT * pada tabel `outlets` (filter `is_active = true`). Akibatnya field sensitif bocor ke siapapun yang punya anon key:
- `settings.payment_methods` (`["cash", "qris", "debit", "credit", "ewallet", "transfer"]`)
- `loyalty_settings` (`{points_per_rupiah, redeem_rate, tier_threshold}`)

**Reproduksi:** `node /tmp/verify-outlets-rls.mjs` (sebelum migration 033) → status 200, dengan `loyalty_settings` + `settings.payment_methods` ter-expose.

**Dampak:**
- Bocor konfigurasi loyalty (internal business logic) ke publik
- Bocor payment methods aktif outlet (info kompetitif)
- Tidak ada eskalasi privilege langsung, hanya disclosure

**Root Cause:**
Policy RLS hanya membatasi BARIS, bukan KOLOM. PostgreSQL RLS tidak punya column-level security — harus pakai `GRANT (col1, col2)` untuk membatasi kolom.

**Fix:**
1. `REVOKE SELECT ON outlets FROM anon` — kunci akses penuh
2. `GRANT SELECT (id, name, address, phone, city, logo_url, is_active) ON outlets TO anon` — column-level grant hanya untuk field aman
3. Buat view `v_outlets_public` (security definer) dengan `settings` yang sudah di-whitelist (hanya `tax_*`, `service_*`, `currency`, `receipt_footer` — NO `payment_methods`)
4. Mobile customer self-order page: ubah embed dari `outlets(*)` → `outlets(id, name, address, phone, city, logo_url, is_active)` supaya kompatibel dengan column grant baru

**Action Required:**
Jalankan `apps/supabase/migrations/033_outlets_anon_field_security.sql` di Supabase → SQL Editor.

**Test Regresi:**
Setelah apply migration, jalankan ulang `node /tmp/verify-outlets-rls.mjs`:
- Test 1 (`SELECT *`) → expect status 500 atau hanya kolom whitelisted, TIDAK ada `loyalty_settings` / `settings.payment_methods`
- Test 2 (`SELECT id,name,logo_url`) → expect status 200 dengan data
- Test 3 (`v_outlets_public`) → expect status 200 dengan settings curated

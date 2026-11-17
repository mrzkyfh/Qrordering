# Security Audit Report
**Tanggal:** 2026-05-27  
**Auditor:** Security Engineer  
**Scope:** Owner Panel (React + Supabase) — Auth, RLS, Input Validation, API  

---

## Executive Summary

Audit menemukan **2 CRITICAL**, **3 HIGH**, **6 MEDIUM**, **3 LOW** vulnerabilities. Semua sudah dibuatkan fix di migration 019-022. Vulnerabilities kritis berkaitan dengan Privilege Escalation via Supabase RLS yang tidak memiliki `WITH CHECK` constraint dan beberapa bypass audit trail.

---

## CRITICAL

### SEC-001 — Privilege Escalation: Kasir Bisa Eskalasi Role ke Owner
**File:** `apps/supabase/migrations/005_rls.sql` — `profiles_update` policy  
**Risiko:** Kasir dapat PATCH `role = 'owner'` via REST API langsung → akses penuh semua data semua outlet  

**Root cause:**
```sql
-- SEBELUM (vulnerable)
CREATE POLICY "profiles_update" ON profiles FOR UPDATE
USING (id = auth.uid() OR is_owner() OR ...);
-- Tidak ada WITH CHECK → USING dipakai untuk check new row juga
-- id = auth.uid() masih TRUE pada new row → RLS lolos!
```

**Fix (migration 022):**
```sql
CREATE POLICY "profiles_update" ON profiles FOR UPDATE
USING (id = auth.uid() OR is_owner() OR ...)
WITH CHECK (
  (id = auth.uid()
    AND role = (SELECT p.role FROM profiles p WHERE p.id = auth.uid())
    AND outlet_id IS NOT DISTINCT FROM (SELECT p.outlet_id FROM profiles p WHERE p.id = auth.uid())
  ) OR is_owner() OR (admin AND outlet=self)
);
```
**Status:** ✅ Fixed in migration 022

---

### SEC-002 — Privilege Escalation: Kasir Bisa Pindah Outlet Sendiri
**File:** `apps/supabase/migrations/005_rls.sql` — `profiles_update` policy  
**Risiko:** Kasir PATCH `outlet_id` ke outlet lain → bisa melihat data outlet lain  
**Root cause:** Sama dengan SEC-001 — tidak ada WITH CHECK  
**Fix:** Sama dengan SEC-001  
**Status:** ✅ Fixed in migration 022

---

## HIGH

### SEC-003 — Kasir Bypass Audit Trail Stok (Direct ingredients UPDATE)
**File:** `apps/supabase/migrations/005_rls.sql` — `ingredients_update` policy  
**Risiko:** Kasir dapat langsung UPDATE `stock_qty` tanpa melalui `stock_transactions` → manipulasi stok tanpa jejak audit  

**Root cause:**
```sql
-- SEBELUM (terlalu permisif)
CREATE POLICY "ingredients_update" ON ingredients FOR UPDATE USING (
  is_owner() OR outlet_id = auth_outlet_id()  -- kasir termasuk!
);
```

**Fix (migration 022):**
```sql
CREATE POLICY "ingredients_update" ON ingredients FOR UPDATE USING (
  is_owner() OR (auth_role() = 'admin' AND outlet_id = auth_outlet_id())
);
```
**Status:** ✅ Fixed in migration 022

---

### SEC-004 — Missing RLS is_owner() pada expenses_insert
**File:** `apps/supabase/migrations/005_rls.sql` — `expenses_insert` policy  
**Risiko:** Owner tidak bisa membuat expense dari web panel (functional bug dengan implikasi security — policy terlalu restrictif untuk owner)  
**Fix (migration 019):** Tambah `is_owner() OR outlet_id = auth_outlet_id()`  
**Status:** ✅ Fixed in migration 019

---

### SEC-005 — Missing RLS is_owner() pada stock_tx_insert
**File:** `apps/supabase/migrations/005_rls.sql` — `stock_tx_insert` policy  
**Risiko:** Owner tidak bisa melakukan stock adjustment dari web panel  
**Fix (migration 020):** Tambah `is_owner() OR outlet_id = auth_outlet_id()`  
**Status:** ✅ Fixed in migration 020

---

## MEDIUM

### SEC-006 — Kasir Dapat Update Outlet Sendiri via API
**File:** `apps/supabase/migrations/005_rls.sql` — `outlets_update` policy (sebelum 021)  
**Risiko:** Kasir dapat mengubah nama, alamat, dan settings outlet sendiri via direct API call  
**Fix (migration 021):** Restrict ke `is_owner() OR (admin AND outlet=self)`  
**Status:** ✅ Fixed in migration 021

---

### SEC-007 — Tidak Ada DB Constraint: expense_date Masa Depan
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `expenses`  
**Risiko:** Data keuangan tidak valid — laporan bisa distorsi dengan tanggal masa depan  
**Fix (migration 022):** `CHECK (expense_date <= CURRENT_DATE)`  
**Status:** ✅ Fixed in migration 022

---

### SEC-008 — Tidak Ada DB Constraint: Promo Percentage > 100%
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `promos`  
**Risiko:** Promo 999% bisa dibuat via API → total order bisa jadi negatif/nol, kerugian bisnis  
**Fix (migration 022):** `CHECK (type != 'percentage' OR value BETWEEN 0 AND 100)`  
**Status:** ✅ Fixed in migration 022

---

### SEC-009 — Tidak Ada DB Constraint: Menu Item Price Negatif
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `menu_items`  
**Risiko:** Item dengan harga negatif dapat mengurangi total order  
**Fix (migration 022):** `CHECK (price >= 0)`  
**Status:** ✅ Fixed in migration 022

---

### SEC-010 — Error Messages Bocorkan Detail Internal (String(err))
**Files:** Multiple pages (DepartmentManager, OrderList, CategoryManager, ExtraManager, LoyaltyManager)  
**Risiko:** PostgrestError object ditampilkan mentah ke user via `String(err)` → bisa bocorkan nama tabel, constraint, struktur DB  
**Fix:** Ganti semua `String(err)` dengan `(err as { message?: string })?.message ?? String(err)`  
**Status:** ✅ Fixed di 5 files

---

### SEC-011 — Outlet Name Constraint Hanya di Frontend
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `outlets`  
**Risiko:** Nama outlet kosong/1 karakter bisa diinput via direct API  
**Fix (migration 021):** `CHECK (char_length(trim(name)) >= 2 AND char_length(name) <= 100)`  
**Status:** ✅ Fixed in migration 021

---

## LOW

### SEC-012 — JSONB settings Tidak Ada Constraint Range
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `outlets.settings`  
**Risiko:** `tax_percent: 999` bisa diinput via API → semua order dihitung dengan pajak 999%  
**Fix (migration 021):** `CHECK ((settings->>'tax_percent')::numeric BETWEEN 0 AND 100 ...)`  
**Status:** ✅ Fixed in migration 021

---

### SEC-013 — Promo Date Range Tidak Ada DB Constraint
**File:** `apps/supabase/migrations/002_tables.sql` — tabel `promos`  
**Risiko:** `end_date < start_date` diterima DB  
**Fix (migration 022):** `CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)`  
**Status:** ✅ Fixed in migration 022

---

### SEC-014 — Voucher Tidak Bisa Dihapus (Tidak Ada DELETE Policy)
**File:** `apps/supabase/migrations/005_rls.sql`  
**Risiko:** Voucher yang sudah expired tidak bisa dibersihkan via API (ambiguous by-design vs oversight)  
**Rekomendasi:** Klarifikasi apakah ini by-design. Jika perlu, tambah DELETE policy untuk owner/admin.  
**Status:** ⚠️ Perlu diskusi produk

---

## Temuan Lain (Non-Security)

| Item | Deskripsi | Rekomendasi |
|------|-----------|-------------|
| Error display | `String(err)` pada PostgrestError → `[object Object]` | ✅ Fixed |
| adjust_stock RPC | SECURITY INVOKER → kena RLS, perlu migration 018+020 diapply | Apply migrations |
| close_shift RPC | SECURITY INVOKER, membutuhkan shifts_update permission kasir | ✅ OK |

---

## Migrations yang Perlu Diapply ke Supabase (URUT)

| No | File | Deskripsi | Priority |
|----|------|-----------|----------|
| 1 | `018_db_refactoring.sql` | adjust_stock & close_shift RPC functions | HIGH |
| 2 | `019_fix_expenses_rls.sql` | expenses_insert allow owner | HIGH |
| 3 | `020_fix_stock_tx_rls.sql` | stock_tx_insert allow owner | HIGH |
| 4 | `021_outlets_constraints.sql` | outlet name/settings constraints + update RLS | MEDIUM |
| 5 | `022_security_hardening.sql` | CRITICAL: privilege escalation fix + constraints | **CRITICAL** |

---
---

# Security Audit — Round 6 (Full-Stack Sweep)
**Tanggal:** 2026-07-05
**Auditor:** Security Engineer
**Scope:** Owner Panel + Customer Menu (React) + Mobile POS (Flutter) + Supabase (RLS/RPC/migrations 001–082)

## Executive Summary — Round 6

Posture matang. 8 ronde audit sebelumnya sudah menutup privilege-escalation, audit-log injection, dan search_path hijacking. Sweep penuh ini **tidak menemukan CRITICAL/HIGH baru**. Temuan tersisa: **3 MEDIUM**, **2 LOW**, sisanya kontrol positif yang terverifikasi.

**Kontrol positif terverifikasi (evidence-based):**
- ✅ PIN di-hash **bcrypt** (`crypt(p_pin, gen_salt('bf'))`), tidak ada plaintext — `047`, `065`
- ✅ Tidak ada `service_role`/secret key ter-hardcode di source (owner-panel, customer-menu, mobile). Hanya anon key (memang publik by-design)
- ✅ Tidak ada `.env` asli ter-commit (hanya `.env.example`)
- ✅ Tidak ada sink XSS (`dangerouslySetInnerHTML`/`innerHTML`/`eval`) di web apps
- ✅ RLS enabled 25+ tabel, tidak ada `DISABLE ROW LEVEL SECURITY`
- ✅ Audit-log injection ditutup — `WITH CHECK (actor_id = auth.uid())` — `024`
- ✅ State-machine status order divalidasi trigger (`draft/confirmed` only on insert) — `080`
- ✅ **Line-item price floor**: trigger `validate_order_item_price` menolak `unit_price < harga katalog` → anti-underpay per item — `074`/`076`
- ✅ Tenant scoping RLS (`auth_outlet_id()`) — `048`
- ✅ `search_path` di-pin di semua `SECURITY DEFINER` — `061`
- ✅ Grant RPC sensitif sudah di-revoke dari public — `062`

---

## MEDIUM

### SEC-R6-001 — Order Header `total_amount` Tidak Direkonsiliasi dengan Line Items
**File:** `apps/supabase/migrations/025_business_logic_fixes.sql:67` (hanya `total_amount >= 0`)
**Risiko:** Trigger `validate_order_item_price` melindungi `unit_price` per item, TAPI tidak ada trigger yang memaksa `orders.total_amount = SUM(order_items.unit_price * quantity) (+options)`. Klien self-order (anon) dapat mengirim item harga valid namun set `total_amount` header lebih rendah. Jika alur pembayaran membaca `total_amount` header (bukan menghitung ulang), pelanggan bisa bayar kurang.
**Rekomendasi:** Tambah trigger `AFTER INSERT/UPDATE` pada `order_items` yang menghitung ulang & meng-update `orders.total_amount` server-side, ATAU trigger validasi yang menolak commit bila header ≠ sum item. Jangan pernah percaya total dari klien.
**Status:** ⚠️ Perlu fix

### SEC-R6-002 — Enumerasi Nomor Telepon Pelanggan via Loyalty (Anon, Tanpa Rate-Limit)
**File:** `apps/supabase/migrations/041_loyalty_order_integration.sql:23-49` — `find_loyalty_member_by_phone`
**Risiko:** RPC `SECURITY DEFINER`, di-`GRANT ... TO anon`, menerima `p_phone` exact-match dan mengembalikan `full_name` + `phone` + `points`. Tanpa rate-limit, penyerang dapat brute-force ruang nomor telepon → panen PII pelanggan (nama) + saldo poin. Termasuk risiko privasi (PDP).
**Rekomendasi:** (a) batasi output ke boolean/`member_id` saja bila hanya untuk attach ke order; jangan bocorkan `full_name`; (b) terapkan rate-limit (mis. Supabase Edge Function + IP throttle, atau tabel attempt-counter); (c) pertimbangkan pencocokan hanya bila dikombinasikan token order aktif.
**Status:** ⚠️ Perlu fix

### SEC-R6-003 — Tidak Ada Lockout / Throttle pada Verifikasi PIN
**File:** `apps/supabase/migrations/047_user_pin_and_refund.sql:60-64`, `065_pin_hierarchy_and_approval.sql:284-291`
**Risiko:** PIN 4–6 digit diverifikasi via bcrypt (lambat, baik) namun **tanpa penghitung percobaan/lockout**. Endpoint dapat dipanggil berulang → brute-force online PIN (ruang 10^4–10^6) untuk otorisasi refund/void tetap layak diserang bila attacker sudah authenticated sebagai staf level rendah.
**Rekomendasi:** Tambah kolom `pin_fail_count` + `pin_locked_until` di `profiles`; increment saat gagal, lock (mis. 5 gagal → tunggu 15 menit). Reset saat sukses. Terapkan di dalam fungsi verify (SECURITY DEFINER).
**Status:** ⚠️ Perlu fix

---

## LOW

### SEC-R6-004 — Permukaan Anon Luas (Promo/Loyalty/Auth Helpers)
**File:** `040`, `041`, `043`, `082` — banyak RPC `TO anon`
**Risiko:** `validate_promo_code`, `apply_promo_usage`, `award_loyalty_points`, `redeem_loyalty_points`, `auth_role()`, `auth_rank()` dapat dipanggil anon. Secara individu ter-scope outlet, tapi tanpa rate-limit memungkinkan probing/abuse (mis. brute-force kode promo, spam redeem). `auth_role()/auth_rank()` untuk anon mengembalikan default (tidak eskalasi) — aman, tapi perlu didokumentasikan.
**Rekomendasi:** Rate-limit di edge; audit ulang setiap RPC anon untuk memastikan efek samping idempoten & ter-scope. Konfirmasi `apply_promo_usage`/`redeem_loyalty_points` idempoten terhadap replay.
**Status:** ℹ️ Monitor

### SEC-R6-005 — Registry Printer Device-Local (SharedPreferences) Tidak Terenkripsi
**File:** `apps/mobile/qrordering/lib/shared/services/printer_service.dart`
**Risiko:** Konfigurasi printer (MAC/host/port) disimpan plaintext di SharedPreferences. Bukan rahasia tinggi, tapi pada device rooted bisa dibaca/diubah. Dampak rendah (bukan kredensial).
**Rekomendasi:** Terima sebagai risiko rendah, atau pindah ke `flutter_secure_storage` bila device sharing jadi concern.
**Status:** ℹ️ Accept/Monitor

---

## Ringkasan Prioritas Fix — Round 6

| ID | Severity | Judul | Aksi |
|----|----------|-------|------|
| SEC-R6-001 | MEDIUM | Header total tak direkonsiliasi | Trigger recompute `total_amount` server-side |
| SEC-R6-002 | MEDIUM | Enumerasi phone loyalty | Kurangi output PII + rate-limit |
| SEC-R6-003 | MEDIUM | Tak ada lockout PIN | Attempt-counter + lockout di verify fn |
| SEC-R6-004 | LOW | Permukaan anon luas | Rate-limit edge + audit idempotensi |
| SEC-R6-005 | LOW | Printer registry plaintext | Accept / secure storage |

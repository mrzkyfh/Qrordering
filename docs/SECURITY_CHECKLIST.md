# Security Checklist — Owner Panel
**Tanggal:** 2026-05-27  
**Versi:** 1.0  

---

## A. Autentikasi & Session

| # | Item | Status | Catatan |
|---|------|--------|---------|
| A-01 | Login hanya melalui Supabase Auth (email+password) | ✅ | Tidak ada bypass auth |
| A-02 | JWT diverifikasi server-side di setiap request | ✅ | Supabase menangani otomatis |
| A-03 | Session expired redirect ke login | ✅ | AuthContext + ProtectedRoute |
| A-04 | Logout menghapus semua token lokal | ✅ | `supabase.auth.signOut()` |
| A-05 | Password minimum 8 karakter (frontend) | ✅ | Fixed — StaffManager schema |
| A-06 | Tidak ada password disimpan plain text | ✅ | Supabase Auth menangani hash |
| A-07 | Role kasir tidak bisa akses web panel | ✅ | DashboardRedirect menampilkan halaman akses terbatas |
| A-08 | PIN staf di-hash bcrypt, bukan plaintext | ✅ | `crypt(p_pin, gen_salt('bf'))` — migrasi 047/065 |
| A-09 | Verifikasi PIN punya lockout/throttle | ❌ | **SEC-R6-003** — belum ada attempt-counter |

---

## B. Otorisasi & Row Level Security (RLS)

| # | Item | Status | Catatan |
|---|------|--------|---------|
| B-01 | Semua tabel memiliki RLS diaktifkan | ✅ | migration 005_rls.sql |
| B-02 | `profiles_update` memiliki WITH CHECK constraint | ✅ | Fixed — migration 022 |
| B-03 | Kasir tidak bisa eskalasi role ke owner/admin | ✅ | Fixed — migration 022 (SEC-001) |
| B-04 | Kasir tidak bisa pindah outlet sendiri | ✅ | Fixed — migration 022 (SEC-002) |
| B-05 | Owner bisa INSERT expenses | ✅ | Fixed — migration 019 (SEC-004) |
| B-06 | Owner bisa INSERT stock_transactions | ✅ | Fixed — migration 020 (SEC-005) |
| B-07 | Kasir tidak bisa langsung UPDATE stock_qty | ✅ | Fixed — migration 022 (SEC-003) |
| B-08 | Hanya owner/admin yang bisa UPDATE outlets | ✅ | Fixed — migration 021 (SEC-006) |
| B-09 | Data antar outlet tidak bocor (multi-tenant isolation) | ✅ | `auth_outlet_id()` di semua policy |
| B-10 | Owner bisa melihat semua outlet | ✅ | `is_owner()` bypass outlet filter |
| B-11 | Voucher tidak bisa dihapus tanpa kebijakan eksplisit | ⚠️ | SEC-014 — perlu keputusan produk |

---

## C. Validasi Input

| # | Item | Status | Catatan |
|---|------|--------|---------|
| C-01 | Semua form menggunakan Zod schema validation | ✅ | React Hook Form + zodResolver |
| C-02 | Nama outlet minimal 2 karakter (DB constraint) | ✅ | Fixed — migration 021 |
| C-03 | Harga menu item tidak bisa negatif (DB constraint) | ✅ | Fixed — migration 022 |
| C-04 | Promo persentase 0-100% (DB constraint + frontend) | ✅ | Fixed — migration 022 + PromoManager |
| C-05 | Promo end_date >= start_date (DB constraint + frontend) | ✅ | Fixed — migration 022 + PromoManager |
| C-06 | Expense date tidak masa depan (DB constraint) | ✅ | Fixed — migration 022 |
| C-07 | Tax percent 0-100% (DB constraint) | ✅ | Fixed — migration 021 |
| C-08 | Service charge 0-100% (frontend validation) | ✅ | Fixed — ChargesSettings |
| C-09 | Minimal 1 metode pembayaran aktif | ✅ | Fixed — PaymentManager |
| C-10 | Outlet wajib dipilih untuk kasir | ✅ | Fixed — StaffManager refine |
| C-11 | Poin loyalitas tidak bisa negatif | ✅ | Fixed — useLoyalty.ts |

---

## D. Error Handling & Information Disclosure

| # | Item | Status | Catatan |
|---|------|--------|---------|
| D-01 | Error message tidak expose struktur database | ✅ | Fixed — 5 file (SEC-010) |
| D-02 | `String(err)` diganti dengan `err?.message` | ✅ | DepartmentManager, OrderList, CategoryManager, ExtraManager, LoyaltyManager |
| D-03 | PostgrestError ditangani sebagai plain object | ✅ | `(err as { message?: string })?.message ?? String(err)` |
| D-04 | Console.log tidak output data sensitif | ✅ | Tidak ada log kredensial |
| D-05 | Stack trace tidak ditampilkan ke user | ✅ | Hanya `message` yang ditampilkan |

---

## E. Keamanan Data

| # | Item | Status | Catatan |
|---|------|--------|---------|
| E-01 | API key Supabase hanya di env variable | ✅ | `.env` (VITE_SUPABASE_*) |
| E-02 | Anon key tidak bisa bypass RLS | ✅ | RLS menggunakan `auth.uid()` |
| E-03 | Service role key tidak digunakan di frontend | ✅ | Hanya anon key di client |
| E-04 | Voucher code dibuat dengan `crypto.getRandomValues()` | ✅ | Fixed — useVouchers.ts |
| E-05 | Stok adjustment menggunakan RPC dengan row lock | ✅ | Fixed — adjust_stock() FOR UPDATE |
| E-06 | Tidak ada race condition di stock_qty update | ✅ | Fixed — migration 018 + useIngredients |
| E-07 | selectedOutletId dipersist di localStorage (bukan sessionStorage) | ✅ | OutletContext — data non-sensitif |

---

## F. Export & Output

| # | Item | Status | Catatan |
|---|------|--------|---------|
| F-01 | CSV export sanitized dari formula injection | ✅ | Fixed — Reports.tsx `sanitizeCSVValue()` |
| F-02 | Excel export HTML-escaped untuk XSS | ✅ | Fixed — Reports.tsx `escapeHtml()` |
| F-03 | QR code print tidak inject code ke halaman | ✅ | Fixed — QRManager `printQR()` |

---

## G. Infrastruktur & Konfigurasi

| # | Item | Status | Catatan |
|---|------|--------|---------|
| G-01 | HTTPS enforced di production | ✅ | Supabase default HTTPS |
| G-02 | CORS dikonfigurasi di Supabase dashboard | ✅ | Hanya origin yang diizinkan |
| G-03 | Environment variables tidak di-commit ke repo | ✅ | `.env` ada di `.gitignore` |
| G-04 | Menu base URL dapat dikonfigurasi via env | ✅ | Fixed — QRManager `VITE_MENU_BASE_URL` |

---

## H. Audit Trail

| # | Item | Status | Catatan |
|---|------|--------|---------|
| H-01 | Void order dicatat dengan alasan | ✅ | `void_reason` di orders |
| H-02 | Stock adjustment dicatat di stock_transactions | ✅ | adjust_stock() RPC selalu insert record |
| H-03 | Order audit log tersedia di detail pesanan | ✅ | useOrderAuditLog + timeline UI |
| H-04 | Kasir tidak bisa bypass audit trail stok | ✅ | Fixed — migration 022 (SEC-003) |

---

## Ringkasan Status

| Tingkat | Total | Selesai | Pending |
|---------|-------|---------|---------|
| CRITICAL | 2 | 2 | 0 |
| HIGH | 3 | 3 | 0 |
| MEDIUM | 6 | 6 | 0 |
| LOW | 3 | 2 | 1 (SEC-014 — perlu diskusi) |
| **Total** | **14** | **13** | **1** |

---

## Migrations yang Harus Diapply (Urutan)

```
018_db_refactoring.sql       — adjust_stock & close_shift RPC
019_fix_expenses_rls.sql     — expenses_insert allow owner
020_fix_stock_tx_rls.sql     — stock_tx_insert allow owner
021_outlets_constraints.sql  — outlet name/settings constraints + RLS
022_security_hardening.sql   — CRITICAL: privilege escalation fix + constraints
```

**PENTING:** Apply dalam urutan tersebut. Jangan skip atau ubah urutan.

---

## Round 6 — Item Terbuka (2026-07-05, migrasi s/d 082)

| # | Item | Status | Ref |
|---|------|--------|-----|
| R6-01 | `order_items.unit_price` ≥ harga katalog (anti-underpay per item) | ✅ | trigger `validate_order_item_price` (074/076) |
| R6-02 | `orders.total_amount` direkonsiliasi server-side dgn line items | ❌ | **SEC-R6-001** — hanya cek `>= 0` |
| R6-03 | `find_loyalty_member_by_phone` batasi PII + rate-limit | ❌ | **SEC-R6-002** — anon, bocorkan nama+poin |
| R6-04 | Lockout/throttle verifikasi PIN | ❌ | **SEC-R6-003** |
| R6-05 | Rate-limit RPC anon (promo/loyalty) | ⚠️ | **SEC-R6-004** — monitor |
| R6-06 | Tidak ada secret/service_role ter-hardcode | ✅ | verified (owner-panel/customer-menu/mobile) |
| R6-07 | Tidak ada `.env` asli ter-commit | ✅ | hanya `.env.example` |
| R6-08 | Tidak ada sink XSS di web apps | ✅ | no `dangerouslySetInnerHTML`/`eval` |
| R6-09 | `search_path` di-pin pada semua SECURITY DEFINER | ✅ | migrasi 061 |
| R6-10 | Audit-log tak bisa di-inject (`actor_id = auth.uid()`) | ✅ | migrasi 024 |

**Prioritas fix berikutnya:** SEC-R6-001 → SEC-R6-003 → SEC-R6-002 (semua MEDIUM).

# Laporan Audit Keamanan — Owner Panel

> **Catatan status (2026-07-30):** dokumen ini adalah baseline historis (audit
> 2026-06-02), bukan representasi otomatis kondisi production saat ini. Temuan
> yang sudah ditangani diverifikasi ulang melalui `qa/sql/audit_*.sql`,
> `supabase db advisors`, lint/build, dan regression production. Gunakan hasil
> audit terbaru tersebut untuk release gate; bagian di bawah dipertahankan
> sebagai riwayat risiko dan alasan mitigasi.

> **Addendum release gate (2026-07-30):** RPC `validate_loyalty_redeem` dan
> `redeem_loyalty_points` diperketat melalui migration
> `173_harden_loyalty_redemption_scope.sql`. Keduanya sekarang hanya dapat
> dipanggil role POS terautentikasi, tidak dieksekusi oleh `anon`, dan memeriksa
> outlet/order/member sebelum membaca atau mengubah saldo. Verifikasi remote:
> `anon_exec=false`, `authenticated_exec=true`, guard `auth.uid()` dan
> `auth_outlet_id()` aktif.

> **Addendum internal RPC (2026-07-30):** migration
> `174_harden_internal_stock_and_approval_scope.sql` mencabut hak `anon` dan
> `authenticated` dari `deduct_stock_for_items` serta `_find_approver`.
> Keduanya kini hanya dapat dipanggil `service_role`; pemanggilan REST anonim
> terverifikasi ditolak (`401`). Helper approval juga memvalidasi sesi dan role
> POS sebelum dipakai oleh alur refund/void. `supabase db advisors` tidak
> menemukan isu security baru setelah migration ini.

> **Addendum integritas harga (2026-07-30):** migration
> `175_harden_catalog_price_integrity.sql` memperketat validasi harga item.
> Harga POS sekarang harus cocok dengan harga katalog + ekstra atau salah satu
> variant yang terdaftar; harga arbitrer dari client ditolak. Regression test
> `qa/sql/test_catalog_price_integrity.sql` membuktikan harga manipulatif gagal
> dan variant valid tetap diterima.

- **Tanggal audit:** 2026-06-02
- **Scope:** `apps/owner-panel` (SPA React + Vite, Cloudflare Pages) beserta lapisan RLS Supabase yang menjadi sandaran keamanannya.
- **Auditor:** Security Engineer
- **Model ancaman singkat:** Aplikasi multi-tenant (banyak outlet). Klien hanya memakai **anon key** + JWT user; **batas keamanan sesungguhnya = Row Level Security (RLS) di Supabase**. Maka temuan RLS yang lemah berdampak langsung ke owner-panel.

## Ringkasan Temuan

| # | Tingkat | Temuan | Lokasi |
|---|---------|--------|--------|
| 1 | **CRITICAL** | RLS over-permissive `USING (TRUE)` → kebocoran & tulis lintas-outlet | `038_order_item_options.sql`, `039_menu_extras_schema.sql`, `009_inventory_recipes.sql` |
| 2 | **HIGH** | Kredensial owner pernah ter-hardcode di repo | `test_pembayaran.mjs:20-21` |
| 3 | **MEDIUM** | PostgREST filter injection via input pencarian tak disanitasi (`.or()`) | `useLoyalty.ts:14`, `useOrders.ts:85` |
| 4 | **MEDIUM** | Tidak ada security headers (CSP, HSTS, X-Frame-Options) | `wrangler.toml`, `public/` (tak ada `_headers`) |
| 5 | **LOW–MEDIUM** | DOM XSS via `document.write` (nilai `table_number` tak di-escape) | `QRManager.tsx:18-28` |
| 6 | **LOW** | Token sesi Supabase disimpan di `localStorage` (rawan dicuri bila ada XSS) | `src/lib/supabase.ts:11-13` |
| 7 | **LOW** | `.env` tidak eksplisit di `.gitignore` (saat ini ter-ignore via global, rapuh) | `.gitignore` |

---

## 1. CRITICAL — RLS over-permissive (`USING (TRUE)`) → akses lintas-outlet

**Deskripsi.** Beberapa tabel memakai policy RLS `USING (TRUE)` / `WITH CHECK (TRUE)` untuk role `authenticated`. Karena aplikasi multi-outlet, ini berarti **user yang login di outlet A dapat membaca — dan pada beberapa tabel, menulis/mengubah/menghapus — data milik outlet B**. Owner-panel mengandalkan RLS sebagai satu-satunya batas keamanan data, jadi guard di sisi klien (ProtectedRoute) tidak menutup celah ini.

**Lokasi.**
- `apps/supabase/migrations/038_order_item_options.sql:28` — `oio_select ... USING (TRUE)`; baris `31-36` — INSERT/UPDATE `WITH CHECK (TRUE)`.
- `apps/supabase/migrations/039_menu_extras_schema.sql:37,43,46,49` — SELECT/INSERT/UPDATE/DELETE `menu_extras` `USING/WITH CHECK (TRUE)` untuk `authenticated`; `66` — `menu_extra_options` SELECT `USING (TRUE)`; `69` — SELECT untuk `anon USING (TRUE)`.
- `apps/supabase/migrations/009_inventory_recipes.sql:31` — `USING (TRUE) WITH CHECK (TRUE)` (resep/HPP).

**Dampak.** Kebocoran data lintas-tenant (menu, extra, resep, item pesanan) dan—untuk tabel dengan `WITH CHECK (TRUE)`—**manipulasi data outlet lain** (mis. mengubah harga extra, menghapus resep). Untuk bisnis multi-outlet ini termasuk pelanggaran isolasi tenant.

**Rekomendasi.**
- Ganti semua `USING (TRUE)` dengan predikat ber-scope outlet, konsisten dengan pola di `005_rls.sql`:
  ```sql
  -- contoh untuk menu_extras
  USING (is_owner() OR outlet_id = auth_outlet_id())
  WITH CHECK (is_owner() OR outlet_id = auth_outlet_id())
  ```
- Untuk tabel anak tanpa kolom `outlet_id` (mis. `menu_extra_options`, `order_item_options`), scope lewat join ke induknya:
  ```sql
  USING (EXISTS (SELECT 1 FROM menu_extras e
                 WHERE e.id = menu_extra_options.extra_id
                   AND (is_owner() OR e.outlet_id = auth_outlet_id())))
  ```
- Untuk akses `anon` (menu publik), batasi ke baris yang memang publik (mis. `is_active = true`) dan hanya `SELECT`, jangan `USING (TRUE)` menyeluruh.
- Buat migration baru (jangan ubah migration lama yang sudah ter-apply) yang `DROP POLICY` lama lalu `CREATE POLICY` ber-scope.

---

## 2. HIGH — Kredensial ter-hardcode di repository

**Deskripsi.** File skrip uji pernah menyimpan email owner asli dan password **plaintext**, ikut ter-commit.

**Lokasi.** `apps/owner-panel/test_pembayaran.mjs:20-21`
```js
await emailInput.fill(process.env.E2E_EMAIL ?? '')
await passInput.fill(process.env.E2E_PASSWORD ?? '')
```

**Dampak.** Siapa pun dengan akses repo dapat memperoleh kredensial login owner yang pernah tercatat di histori Git.

**Rekomendasi.**
- **Segera rotasi/ganti password** akun yang pernah bocor dan gunakan akun QA terpisah.
- Pindahkan kredensial uji ke environment variable (`process.env.E2E_EMAIL` / `E2E_PASSWORD`); jangan hardcode.
- Tambahkan scan secret (mis. gitleaks) di CI.
- Pertimbangkan menghapus file dari riwayat git (`git filter-repo`) bila repo pernah dibagikan.
- Terapkan kebijakan password kuat untuk akun staff (lihat checklist).

---

## 3. MEDIUM — PostgREST filter injection (`.or()` dgn input tak disanitasi)

**Deskripsi.** Input pencarian dari user di-interpolasi langsung ke string filter PostgREST `.or(...)`. Karakter koma `,` dan operator PostgREST (`.ilike.`, `.gt.`, dst.) di dalam input dapat **mengubah struktur filter** (menambah kondisi OR ke kolom lain). RLS tetap membatasi baris yang boleh diakses, sehingga ini **bukan bypass RLS**, tetapi memungkinkan manipulasi filter di dalam scope yang diizinkan (kebocoran antar-kolom, error, atau pengembalian baris yang tak diinginkan).

**Lokasi.**
- `apps/owner-panel/src/hooks/queries/useLoyalty.ts:14`
  ```ts
  if (search) q = q.or(`phone.ilike.%${search}%,name.ilike.%${search}%`)
  ```
- `apps/owner-panel/src/hooks/queries/useOrders.ts:85`
  ```ts
  q = q.or(`order_number.ilike.%${s}%,customer_name.ilike.%${s}%`)
  ```
- (Risiko lebih rendah, nilai dari date-picker) `useSales.ts:241-242`.

**Rekomendasi.**
- Sanitasi input sebelum dipakai: buang/escape karakter berbahaya bagi sintaks PostgREST:
  ```ts
  const safe = search.replace(/[,()%*:\\]/g, '').trim()
  if (safe) q = q.or(`phone.ilike.%${safe}%,name.ilike.%${safe}%`)
  ```
- Atau hindari `.or()` string: lakukan dua query `.ilike()` terpisah lalu gabungkan, atau buat RPC pencarian yang menerima parameter ter-bind.
- Batasi panjang input pencarian.

---

## 4. MEDIUM — Tidak ada security headers (CSP / HSTS / X-Frame-Options)

**Deskripsi.** Tidak ada file `public/_headers` dan `wrangler.toml` tidak men-set header keamanan. SPA disajikan Cloudflare Pages tanpa Content-Security-Policy, X-Frame-Options, HSTS, X-Content-Type-Options, atau Referrer-Policy.

**Lokasi.** `apps/owner-panel/wrangler.toml`, `apps/owner-panel/public/` (hanya ada `_redirects`).

**Dampak.** Tanpa `X-Frame-Options/CSP frame-ancestors` → rawan **clickjacking**. Tanpa CSP → dampak XSS (mis. temuan #5) tidak diredam. Tanpa HSTS → rawan downgrade.

**Rekomendasi.** Tambahkan `apps/owner-panel/public/_headers`:
```
/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Permissions-Policy: camera=(self), microphone=()
  Content-Security-Policy: default-src 'self'; img-src 'self' data: blob:; connect-src 'self' https://*.supabase.co wss://*.supabase.co; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'
```
> Sesuaikan domain Supabase & sumber font/CDN yang dipakai. Uji CSP di staging (mode report-only dulu) agar tidak memblokir aset sah.

---

## 5. LOW–MEDIUM — DOM XSS via `document.write` (cetak QR)

**Deskripsi.** Fungsi cetak QR menulis HTML ke window baru memakai `document.write`, menyisipkan `table_number` tanpa escaping. `table_number` bersumber dari DB (diisi owner/admin). Bila berisi markup/`<script>`, akan tereksekusi di window cetak (stored XSS terbatas).

**Lokasi.** `apps/owner-panel/src/pages/admin/QRManager.tsx:18-28`
```ts
win.document.write(`... <title>QR Code Meja ${tableNumber}</title> ... <h2>Meja ${tableNumber}</h2> ...`)
```

**Dampak.** Eksekusi skrip di konteks window cetak (bisa dipakai untuk phishing/penyalahgunaan bila penyerang dapat mengatur `table_number`). `dataUrl` aman (PNG hasil generate).

**Rekomendasi.**
- Escape nilai dinamis sebelum disisipkan:
  ```ts
  const esc = (s: string) => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!))
  ```
  lalu pakai `esc(tableNumber)`.
- Lebih aman: bangun DOM dengan `document.createElement` + `textContent` alih-alih `document.write` string.
- Validasi `table_number` saat input (alfanumerik saja).

---

## 6. LOW — Token sesi di `localStorage`

**Deskripsi.** Klien Supabase memakai `persistSession: true` (default → simpan JWT di `localStorage`). Token di `localStorage` dapat dicuri oleh skrip apa pun bila terjadi XSS.

**Lokasi.** `apps/owner-panel/src/lib/supabase.ts:11-13`.

**Dampak.** Defense-in-depth: bila ada XSS (lihat #5) + tanpa CSP (#4), token bisa diekstrak → pembajakan sesi.

**Rekomendasi.** Risiko ini diterima secara umum untuk SPA Supabase, namun kurangi dengan: menerapkan CSP ketat (#4), menutup vektor XSS (#5), dan menjaga TTL token wajar. (Opsi lanjutan: simpan sesi di memori + refresh via cookie httpOnly memerlukan backend khusus — di luar scope saat ini.)

---

## 7. LOW — `.env` tidak eksplisit di `.gitignore`

**Deskripsi.** `.gitignore` owner-panel tidak memuat entri `.env` secara eksplisit (`*.local` tidak mencakup `.env`). Saat ini `git check-ignore` melaporkan `.env` ter-ignore (kemungkinan via global excludes), tapi ini rapuh untuk kontributor lain.

**Lokasi.** `apps/owner-panel/.gitignore`.

**Rekomendasi.** Tambahkan baris eksplisit:
```
.env
.env.*
!.env.example
.dev.vars
```

---

## Hal yang Sudah Baik (Positif)

### Addendum audit 2026-07-30

- Migration 175 mengunci validasi harga item pada harga katalog + ekstra/varian
  yang terdaftar. Harga arbitrer yang dikirim client kini ditolak dan sudah
  diuji pada `qa/sql/test_catalog_price_integrity.sql`.
- Migration 176 menghapus hak `UPDATE`/`DELETE` langsung pada `order_items`
  untuk `anon`/`authenticated`. Perubahan item wajib melalui RPC transaksi
  resmi agar subtotal, pajak, stok, dan pembayaran tetap konsisten. Jalur RPC
  yang digunakan aplikasi tetap berjalan karena memakai `SECURITY DEFINER`.

- Klien hanya memakai **anon key**; tidak ada `service_role`/secret di kode klien (`src/`). ✅
- Anon key & URL via `import.meta.env` (VITE_), `.env` saat ini tidak ter-track git. ✅
- Ada **ProtectedRoute** dengan `allowedRoles` + `DashboardRedirect` berbasis role (UX guard). ✅
- Validasi input form login pakai **zod** (`LoginPage.tsx`). ✅
- React meng-escape output by default (tidak ada `dangerouslySetInnerHTML`). ✅
- View laporan sudah diperbaiki ke `security_invoker` (migration 047) — RLS ditegakkan untuk view. ✅

## Prioritas Perbaikan

1. **CRITICAL #1** — perbaiki RLS `USING (TRUE)` (isolasi tenant) → migration baru.
2. **HIGH #2** — rotasi password owner + hapus kredensial hardcode.
3. **MEDIUM #3, #4** — sanitasi filter pencarian; tambah `_headers`.
4. **LOW #5, #6, #7** — escape QR print; CSP; perketat `.gitignore`.

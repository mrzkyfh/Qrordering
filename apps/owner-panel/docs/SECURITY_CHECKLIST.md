# Checklist Keamanan — Owner Panel

Status: ✅ aman / ⚠️ perlu perbaikan / ⬜ belum diverifikasi.
Tanggal: 2026-06-02. Referensi detail: [SECURITY_AUDIT.md](./SECURITY_AUDIT.md).

## 1. Autentikasi & Otorisasi
- [x] ✅ Login via Supabase Auth (email/password), bukan auth buatan sendiri.
- [x] ✅ Route dilindungi `ProtectedRoute` + `allowedRoles` (guard UX).
- [x] ✅ Redirect berbasis role (`DashboardRedirect`).
- [x] ✅ **Batas keamanan data = RLS** — policy `USING (TRUE)` di-scope per outlet via migration `048_rls_tenant_scope.sql` (⏳ perlu `supabase db push`).
- [ ] ⬜ Verifikasi semua tabel sensitif punya RLS aktif + policy ber-scope `outlet_id`.
- [ ] ⚠️ Kebijakan password kuat untuk staff (min 8, hindari `admin123` dst).
- [ ] ⬜ Rate-limit / proteksi brute-force login (andalkan setelan Supabase Auth).

## 2. Validasi Input & Sanitasi
- [x] ✅ Form login divalidasi dengan zod.
- [x] ✅ Input pencarian `.or()` PostgREST disanitasi via `src/lib/search.ts` (`useLoyalty`, `useOrders`).
- [ ] ⬜ Validasi zod pada semua form mutasi (menu, harga, extra, outlet).
- [ ] ⬜ Batasi panjang & tipe input field bebas (nama, catatan).

## 3. Penyimpanan Data Sensitif
- [x] ✅ Tidak ada `service_role`/secret di kode klien.
- [x] ✅ `.env` tidak ter-track git; hanya `anon key` + URL (VITE_).
- [x] ✅ `.env`, `.env.*`, `.dev.vars` eksplisit di `.gitignore` (kecuali `.env.example`).
- [x] ✅ Kredensial hardcode di `test_pembayaran.mjs` dihapus → pakai env `E2E_EMAIL`/`E2E_PASSWORD`. ⏳ **Rotasi password owner masih wajib** (sudah bocor di git).
- [x] ✅ (Diterima) Token sesi di `localStorage` — mitigasi via CSP + tutup XSS.
- [ ] ⬜ Aktifkan secret scanning (gitleaks) di CI.

## 4. Kerentanan Umum
- [x] ✅ XSS output: React auto-escape; tidak ada `dangerouslySetInnerHTML`.
- [x] ✅ DOM XSS: `document.write` di `QRManager` kini meng-escape `table_number` (`escapeHtml`).
- [x] ✅ SQL Injection: query lewat supabase-js (parameterized); **catatan**: hindari string filter `.or()` tak disanitasi (lihat #3).
- [ ] ⬜ CSRF: Supabase pakai bearer token (bukan cookie ambient) → risiko CSRF rendah; pastikan tidak ada endpoint berbasis cookie.
- [x] ✅ Tidak ada `eval()` / `innerHTML` di `src/`.

## 5. Konfigurasi Keamanan (HTTPS, CORS, Headers)
- [x] ✅ HTTPS via Cloudflare Pages (default).
- [x] ✅ **Security headers** ditambahkan di `public/_headers`:
  - [x] Content-Security-Policy (enforce; uji & turunkan ke report-only bila ada aset terblokir)
  - [x] X-Frame-Options: DENY (anti-clickjacking)
  - [x] X-Content-Type-Options: nosniff
  - [x] Strict-Transport-Security (HSTS)
  - [x] Referrer-Policy: strict-origin-when-cross-origin
  - [x] Permissions-Policy
- [ ] ⬜ CORS: dikelola Supabase; pastikan tidak ada wildcard berlebih pada Edge Function (bila ada).

## 6. Operasional
- [ ] ⬜ Audit dependensi rutin (`npm audit`) + update.
- [ ] ⬜ Logging akses sensitif (void/refund sudah ada audit trail di DB).
- [ ] ⬜ Review berkala policy RLS setiap menambah tabel baru (default: deny → scope outlet).
- [ ] ⬜ Backup & uji restore database.

---

### Aksi Prioritas (urut)
1. Migration baru: ganti RLS `USING (TRUE)` → scope `outlet_id` (CRITICAL).
2. Rotasi password owner + hapus kredensial di `test_pembayaran.mjs` (HIGH).
3. Sanitasi input `.or()` pencarian (MEDIUM).
4. Tambah `public/_headers` (MEDIUM).
5. Escape QR print + perketat `.gitignore` (LOW).

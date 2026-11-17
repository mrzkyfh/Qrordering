# Test Plan — Owner Panel (Production Readiness)

**Versi:** 1.0
**Tanggal disusun:** 2026-05-28
**Target rilis:** v1.0 (production)
**Aplikasi:** `apps/owner-panel` — React + Vite + Supabase (PostgreSQL, Auth)

---

## 1. Tujuan

Memastikan owner-panel siap dipakai di production dengan kualitas:
- Tidak ada **CRITICAL** atau **HIGH** bug yang belum di-resolve
- Semua user flow utama (login, kelola menu, kasir, laporan) berfungsi end-to-end
- Performa < 3 detik untuk halaman utama, < 5 detik untuk halaman dengan tabel besar
- Tidak ada data leak via RLS bypass
- Mobile responsive (Android Chrome) untuk semua halaman utama

## 2. Scope

### In-Scope

| Role | Modul | Halaman |
|---|---|---|
| **Owner** | Dashboard | `/owner/dashboard` |
| | Monitoring Cabang | `/owner/branches` |
| | Laporan Keuangan | `/owner/finance` |
| | Manajemen Staff | `/owner/staff` |
| **Admin (Outlet)** | Dashboard | `/admin/dashboard` |
| | Produk | departments, categories, menu, extras |
| | Laporan | reports (ringkasan), sales-breakdown/* (5 tabs) |
| | Pesanan | orders, shifts |
| | Inventori | stock, stock-report |
| | Keuangan | expenses |
| | Operasional | tables, qr-codes |
| | Promosi | promos |
| | Loyalty | loyalty |
| | Pembayaran | payments, receipt, charges, taxes |
| | SDM | staff |
| | Pengaturan | settings |
| **Auth** | Login | `/login` |

### Out-of-Scope (release berikutnya)

- Mobile app (apps/mobile/qrordering) — testing terpisah
- Webhook integrations (belum ada)
- Multi-language (UI saat ini hanya Bahasa Indonesia)

## 3. Strategi Testing

### 3.1 Test levels

| Level | Tooling | Coverage target | Owner |
|---|---|---|---|
| **API / Integration** | `node:test` + fetch ke Supabase REST | Semua view + RPC + RLS | Backend / QA |
| **E2E (browser)** | Playwright (Chromium) | Critical user flows | QA |
| **Manual exploratory** | Browser + DevTools | UI/UX, edge cases, mobile | QA |
| **Visual regression** | Manual screenshot review | Mobile breakpoint | QA |

### 3.2 Test environments

| Env | URL | Database | Untuk |
|---|---|---|---|
| **Local dev** | `http://localhost:5173` | Supabase project shared | Smoke selama development |
| **Production** | `https://qrordering.pages.dev` | Supabase production | Final regression + monitoring |

### 3.3 Test data

- **User QA:** akun khusus dari `E2E_EMAIL` (**lihat BUG-LAP-API-001 — jangan gunakan akun produksi**)
- **Outlet seed:** minimum 1 outlet aktif dengan ≥ 30 hari data transaksi
- **Staff seed:** 1 admin, 1 kasir, 1 dapur per outlet

## 4. Acceptance Criteria (Production-Ready)

Aplikasi dianggap **siap dipakai** ketika semua kriteria berikut terpenuhi:

### 4.1 Bug status
- ✅ 0 CRITICAL bugs unresolved
- ✅ 0 HIGH bugs unresolved kecuali ada workaround terdokumentasi
- ✅ ≤ 5 MEDIUM bugs unresolved
- ✅ Semua bug yang sudah dilaporkan (BUG_REPORT.md, API_TEST_REPORT.md) di-triage

### 4.2 Functional coverage
- ✅ Semua user flow di tabel §6 PASS
- ✅ Semua regression test di REGRESSION_CHECKLIST.md PASS
- ✅ API test suite (`tests/api/laporan-api.test.mjs`) 18/18 PASS (saat ini 16/18 — fix BUG-LAP-API-002 & 003)

### 4.3 Non-functional
- ✅ Login berhasil dalam < 5 detik
- ✅ Halaman dashboard load (data ter-fetch) < 5 detik
- ✅ Tidak ada console error di production build
- ✅ Source maps tidak ter-deploy (sudah di-fix di vite.config.ts)
- ✅ Mobile (375×667) — semua halaman utama tidak ada overflow/scroll horizontal kecuali tabel data
- ✅ RLS — anon role tidak bisa baca data table apapun

### 4.4 Browser support
- ✅ Chrome / Edge (Chromium) latest 2 versi
- ✅ Safari latest 2 versi
- ✅ Firefox latest 2 versi
- ✅ Mobile Chrome (Android) — layout primary mobile

### 4.5 Documentation
- ✅ TEST_PLAN.md (this file)
- ✅ TEST_CASES.md
- ✅ BUG_REPORT.md (updated dengan semua finding)
- ✅ REGRESSION_CHECKLIST.md
- ✅ AUTOMATION_GUIDE.md

## 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Data view (v_*) tidak konsisten dengan TypeScript types | High | High | API test suite per view (sudah ada) |
| RLS bocor — admin outlet A melihat data outlet B | Low | Critical | Manual test cross-outlet + RLS policy review |
| Login user dihapus / password berubah | Medium | High | Monitor BUG-LAP-API-001 status |
| Export PDF gagal pada data besar (jsPDF memory) | Medium | Medium | Test dengan 1000+ rows |
| Date picker timezone bug | Medium | Medium | Test cross-month |
| Realtime subscription lag | Low | Medium | Spot check dengan 2 tab |
| Mobile layout pecah pada device < 360px | Low | Medium | Visual test pada iPhone SE (375) + small Android |

## 6. Test Suite — User Flows Utama (must pass before release)

| ID | Flow | Role | Severity |
|---|---|---|---|
| F-01 | Login dengan email/password valid → redirect ke dashboard | All | CRITICAL |
| F-02 | Login dengan password salah → error message | All | HIGH |
| F-03 | Logout → redirect ke /login | All | HIGH |
| F-04 | Owner switch outlet → data dashboard berubah | Owner | HIGH |
| F-05 | Admin buat menu baru → muncul di POS mobile | Admin | CRITICAL |
| F-06 | Admin edit harga menu → harga update di dashboard | Admin | HIGH |
| F-07 | Admin lihat laporan ringkasan penjualan | Admin | CRITICAL |
| F-08 | Admin lihat laporan per departemen/kategori/menu | Admin | HIGH |
| F-09 | Export CSV → file ter-download, kolom benar | Admin | HIGH |
| F-10 | Export Excel → file ter-download, header orange | Admin | MEDIUM |
| F-11 | Export PDF → file ter-download, layout rapi | Admin | MEDIUM |
| F-12 | Admin tambah staff baru | Admin | HIGH |
| F-13 | Admin hapus staff → tidak muncul di list | Admin | HIGH |
| F-14 | Admin kelola stok bahan baku | Admin | HIGH |
| F-15 | Admin lihat pesanan masuk realtime | Admin | HIGH |
| F-16 | Admin void pesanan → status berubah | Admin | HIGH |
| F-17 | Admin set pajak & service charge | Admin | HIGH |
| F-18 | Admin buat promo dengan tanggal valid | Admin | MEDIUM |
| F-19 | Admin generate QR code meja | Admin | MEDIUM |
| F-20 | Mobile (375px) — sidebar collapse, semua halaman accessible | All | HIGH |

## 7. Schedule

| Fase | Durasi | Output |
|---|---|---|
| **Test design** | 2 hari | TEST_PLAN.md, TEST_CASES.md (selesai) |
| **API test automation** | 1 hari | `tests/api/*.test.mjs` (selesai sebagian) |
| **E2E automation expansion** | 3 hari | Playwright spec per modul |
| **Manual exploratory** | 2 hari | Bug findings di BUG_REPORT.md |
| **Bug fix + retest** | 3 hari | Resolved BUG count, retest |
| **Pre-release regression** | 1 hari | REGRESSION_CHECKLIST.md PASS |
| **Production deploy + smoke** | 0.5 hari | Live monitoring |
| **Total** | **~12 hari** | Production-ready |

## 8. Roles & Responsibility

| Peran | Tanggung jawab |
|---|---|
| QA Engineer | Buat & jalankan test cases, file bug reports, gatekeeper release |
| Backend Dev | Fix bug API/RLS/view, jalankan migration |
| Frontend Dev | Fix bug UI/state, perbaiki responsive |
| Tech Lead | Triage bug severity, approve release |
| Product Manager | Sign-off acceptance criteria |

## 9. Entry & Exit Criteria

### Entry (mulai test cycle)
- Code branch merged ke main
- Build pass di CI
- Migration database up-to-date di test env

### Exit (release approved)
- Semua Acceptance Criteria §4 terpenuhi
- REGRESSION_CHECKLIST.md di-tandatangani QA
- Tech Lead approve release tag

## 10. Reference

- [TEST_CASES.md](./TEST_CASES.md) — detail test case per modul
- [BUG_REPORT.md](./BUG_REPORT.md) — known bugs
- [API_TEST_REPORT.md](./API_TEST_REPORT.md) — API test results
- [REGRESSION_CHECKLIST.md](./REGRESSION_CHECKLIST.md) — pre-release smoke
- [AUTOMATION_GUIDE.md](./AUTOMATION_GUIDE.md) — cara jalankan automated tests
- [BUG_REPORT_TEMPLATE.md](./BUG_REPORT_TEMPLATE.md) — template lapor bug

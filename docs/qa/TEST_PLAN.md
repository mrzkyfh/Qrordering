# Test Plan — Owner Panel
**Versi:** 1.0  
**Tanggal:** 2026-05-27  
**QA Engineer:** QA Agent  
**Scope:** Aplikasi web Owner Panel (React + Supabase)

---

## 1. Tujuan Testing

Memastikan seluruh fitur Owner Panel berjalan sesuai spesifikasi, bebas bug kritis, aman dari akses tidak sah, dan memberikan pengalaman pengguna yang baik.

---

## 2. Scope

### In-Scope
| Modul | Role |
|-------|------|
| Login / Logout | Semua |
| Owner Dashboard | Owner |
| Branch Monitoring (CRUD Outlet) | Owner |
| Finance Report | Owner |
| Owner Staff Manager | Owner |
| Admin Dashboard | Admin/Owner |
| Menu Manager (CRUD + Resep + Gambar) | Admin |
| Category Manager | Admin |
| Stock Manager + Adjustment | Admin |
| Order List + Void | Admin |
| Shift List + Open/Close | Admin |
| Reports (5 tab) + Export | Admin |
| Promo Manager | Admin |
| Loyalty Manager + Point Adjustment | Admin |
| Table Manager | Admin |
| Expense Manager | Admin |
| Staff Manager (Admin view) | Admin |
| Protected Route (role-based access) | Semua |

### Out-of-Scope
- Mobile app (Flutter)
- Supabase backend (unit test DB)
- CI/CD pipeline
- Performance/load testing (fase berikutnya)

---

## 3. Strategi Testing

### Tipe Testing
| Tipe | Tools | Prioritas |
|------|-------|-----------|
| Manual Functional | Browser | P0 |
| Negative/Boundary | Browser | P0 |
| Role-based Access Control | Browser | P0 |
| UI/UX Smoke | Browser | P1 |
| Cross-browser | Chrome, Safari, Firefox | P1 |
| Export (CSV/Excel/PDF) | Browser download | P1 |
| Realtime (WebSocket) | Browser | P2 |

### Prioritas Bug
| Level | Definisi |
|-------|----------|
| Critical (P0) | Blokir fungsi utama, data hilang, akses tidak sah |
| High (P1) | Fitur tidak bekerja, validasi bypass |
| Medium (P2) | UI salah, pesan error tidak tepat |
| Low (P3) | Kosmetik, typo, UX minor |

---

## 4. Environment

| Item | Detail |
|------|--------|
| URL | localhost (dev) |
| Browser utama | Chrome 124+ |
| DB | Supabase (staging) |
| Test user owner | mrzkyfh+owner@gmail.com |
| Test user admin | mrzkyfh+admin@gmail.com |
| Test user kasir | mrzkyfh+kasir@gmail.com |

---

## 5. Entry & Exit Criteria

**Entry Criteria:**
- Aplikasi dapat dibuka di browser tanpa crash
- User test tersedia di semua role
- Database staging memiliki data awal

**Exit Criteria:**
- Semua test case P0 lulus
- Tidak ada bug Critical/High yang open
- Bug Medium ≤ 3 yang open (dengan workaround)

---

## 6. Deliverables

- [x] TEST_PLAN.md
- [x] TEST_CASES.md
- [x] BUG_REPORT_TEMPLATE.md
- [x] REGRESSION_CHECKLIST.md
- [x] AUTOMATION_GUIDE.md
- [x] reports/2026-05-27_OWNER_PANEL_QA_REPORT.md

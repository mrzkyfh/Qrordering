# Infrastructure — Time 420s

Arsitektur **serverless / managed**. Tidak ada server/VM/K8s yang dikelola sendiri.
Stack inti: **Cloudflare Pages** (frontend) + **Supabase** (backend) + **Flutter** (mobile).

> Diperbarui: 2026-06-02. Lihat juga: [CICD_PIPELINE.md](./CICD_PIPELINE.md), [ENVIRONMENT.md](./ENVIRONMENT.md), [MONITORING.md](./MONITORING.md).

---

## 1. Diagram Komponen

```
                    ┌──────────────────────────────┐
   Owner / Admin ──▶│ owner-panel (Vite SPA)        │
                    │ Cloudflare Pages: panel-restoran
                    └───────────────┬──────────────┘
                                    │ HTTPS (anon key + JWT)
   Pelanggan ──────▶ customer-menu (static)         │
                    │ Cloudflare Pages: times420s-menu│
                    └───────────────┤
                                    ▼
   Kasir ──────────▶ mobile (Flutter)  ───────────▶ ┌───────────────────────────┐
   Android/iOS/Web                                   │ Supabase (managed)        │
                                                     │  • Postgres + RLS          │
                                                     │  • Auth (JWT)              │
                                                     │  • Storage (opsional)      │
                                                     │  • Edge Functions:         │
                                                     │     create-staff,          │
                                                     │     clock-in,              │
                                                     │     change-device-password,│
                                                     │     change-staff-password, │
                                                     │     archive-orders,        │
                                                     │     transaction-archive    │
                                                     └───────────────────────────┘
```

## 2. Komponen & Tanggung Jawab

| Komponen | Teknologi | Hosting | Sumber |
|----------|-----------|---------|--------|
| **owner-panel** | React + Vite (SPA) | Cloudflare Pages (`panel-restoran`) | `apps/owner-panel` |
| **customer-menu** | HTML/JS statis | Cloudflare Pages (mis. `times420s-menu`) | `apps/customer-menu` |
| **mobile** | Flutter (Android/iOS/Web) | Play Store / App Store / Pages (web) | `apps/mobile/time420s` |
| **database & auth** | Supabase Postgres + Auth + RLS | Supabase Cloud | `apps/supabase/migrations`, `seeds` |
| **serverless logic** | Supabase Edge Functions (Deno) | Supabase | `apps/supabase/functions`, `supabase/functions` |

## 3. Keamanan sebagai Fondasi Infra

- Klien (web & mobile) **hanya** memakai **anon key** Supabase; tidak ada `service_role` di klien.
- **Batas keamanan data = RLS** (Row Level Security) di Postgres — di-scope per `outlet_id` (lihat migrasi `005_rls.sql`, `048_rls_tenant_scope.sql`).
- Edge Functions yang butuh hak admin (create/delete staff) memakai `service_role` **di server** (secret function), bukan di klien.
- Security headers (CSP/HSTS/X-Frame-Options) via `apps/owner-panel/public/_headers`.
- Audit keamanan: `apps/owner-panel/docs/SECURITY_AUDIT.md`.

## 4. Jaringan & Domain

| Layanan | URL/Host | TLS |
|---------|----------|-----|
| owner-panel | `*.pages.dev` (atau custom domain) | Otomatis (Cloudflare) |
| customer-menu | `times420s-menu.pages.dev` | Otomatis |
| Supabase API | `https://<ref>.supabase.co` | Managed |
| Supabase Realtime | `wss://<ref>.supabase.co` | Managed |

- HTTPS & sertifikat dikelola otomatis oleh Cloudflare & Supabase.
- CORS untuk API diatur Supabase; Edge Functions atur header CORS sendiri.

## 5. Data & State

- **Postgres** (Supabase) = single source of truth. Skema dikelola via **migrations** berurut (`apps/supabase/migrations/NNN_*.sql`), saat ini sampai `048`.
- **Seeds**: `apps/supabase/seeds` (demo data & simulasi transaksi).
- **Realtime**: order/notification via Supabase Realtime (channel per outlet).
- **Storage**: bila dipakai (gambar menu/logo) via Supabase Storage / aset statis di repo.

## 6. Lingkungan (Environments)

| Env | Frontend | Database |
|-----|----------|----------|
| **local** | `npm run dev` / `flutter run` | Supabase Cloud (atau `supabase start` lokal) |
| **preview** | Preview deploy Cloudflare Pages (per branch/PR) | Supabase yang sama (hati-hati) atau project staging |
| **production** | Pages production (branch `main`) | Supabase project production |

> Rekomendasi: **pisahkan project Supabase** untuk staging vs production agar preview deploy tidak menyentuh data produksi. Detail di [ENVIRONMENT.md](./ENVIRONMENT.md).

## 7. Kapasitas & Skala

- Cloudflare Pages: CDN global, auto-scale, gratis untuk skala kecil–menengah.
- Supabase: scale vertikal (plan) + connection pooling (PgBouncer/Supavisor). Pantau koneksi & ukuran DB.
- Tidak perlu Docker/K8s pada skala ini (lihat [DOCKER_SETUP.md](./DOCKER_SETUP.md) untuk alasan & opsi dev lokal).

## 8. Disaster Recovery (ringkas)

- **Backup DB**: aktifkan Point-in-Time Recovery / daily backup di Supabase (sesuai plan). Uji restore berkala.
- **Rollback frontend**: Cloudflare Pages menyimpan setiap deployment → rollback 1 klik ke deployment sebelumnya.
- **Rollback DB**: migration maju-saja; siapkan migration pembalik bila perlu. Jangan edit migration lama yang sudah ter-apply.
- **Secret bocor**: rotasi anon/service key di Supabase + update env Pages/Functions.

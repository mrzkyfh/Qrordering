# Monitoring & Alerting — QR Ordering

Observability untuk stack serverless (Cloudflare Pages + Supabase + Flutter). Fokus: ketersediaan, error, performa DB, dan jejak audit bisnis.

---

## 1. Lapisan Pemantauan

| Lapisan | Tool (built-in) | Yang dipantau |
|---------|-----------------|---------------|
| Frontend (web) | Cloudflare Pages/Web Analytics | Traffic, status build, error deploy, Core Web Vitals |
| Backend/DB | Supabase Dashboard → Logs & Reports | Query lambat, error API/Auth, koneksi, ukuran DB |
| Edge Functions | Supabase → Functions → Logs | Invocation, error, durasi |
| Realtime | Supabase → Realtime | Koneksi, pesan |
| Mobile | Crash/log (lihat §4) | Crash, error runtime |
| Bisnis | Tabel audit di DB | Void/refund/cancel, shift, pembayaran |

## 2. Cloudflare (Frontend)
- **Deployments**: status build per push (sukses/gagal) di dashboard Pages → set notifikasi email/Slack untuk *build failed*.
- **Web Analytics**: aktifkan (gratis, tanpa cookie) untuk pageviews & Web Vitals owner-panel & customer-menu.
- **Uptime**: tambah health check eksternal (mis. UptimeRobot/Cron) ke URL produksi tiap 1–5 menit.

## 3. Supabase (Backend)
- **Logs**: `Logs & Analytics` → API, Postgres, Auth, Functions. Filter error (5xx, auth failures).
- **Reports**: pantau **slow queries**, jumlah koneksi, cache hit. Tambah indeks bila ada query lambat (mis. pencarian, laporan).
- **Database health**: ukuran DB, dead tuples (autovacuum), penggunaan koneksi vs limit (pakai pooler/Supavisor).
- **Auth**: pantau lonjakan login gagal (indikasi brute-force) → pertimbangkan rate-limit/Captcha di Supabase Auth.

## 4. Mobile (Flutter) — disarankan
Belum ada crash reporting. Tambahkan salah satu:
- **Sentry** (`sentry_flutter`) — error + performance + breadcrumbs.
- **Firebase Crashlytics** — crash native + non-fatal.
Integrasi: bungkus `runApp` dalam zone error handler, kirim `FlutterError.onError` & `PlatformDispatcher.onError`.

## 5. Error Tracking Web — disarankan
Tambah **Sentry (browser)** di owner-panel untuk menangkap error JS runtime + sumber. (Jika dipakai, tambahkan domain Sentry ke `connect-src` CSP di `apps/owner-panel/public/_headers`.)

## 6. Metrik Kunci (KPI Teknis)

| Metrik | Target | Sumber |
|--------|--------|--------|
| Uptime web | ≥ 99.9% | Health check eksternal |
| Build success rate | ~100% | Cloudflare Pages |
| API error rate (5xx) | < 1% | Supabase Logs |
| p95 query time | < 300ms | Supabase Reports |
| Auth failure spike | baseline | Supabase Auth logs |
| Crash-free sessions (mobile) | ≥ 99% | Sentry/Crashlytics |
| Koneksi DB | < 80% limit | Supabase |

## 7. Alerting

| Kondisi | Aksi | Kanal |
|---------|------|-------|
| Build Pages gagal | Notifikasi tim | Email/Slack (Cloudflare) |
| Web down (health check) | Page on-call | UptimeRobot → Slack/WA |
| Error rate API naik | Investigasi | Supabase log alert / Sentry |
| Slow query muncul | Tambah indeks | Supabase Reports |
| Lonjakan login gagal | Cek brute-force | Supabase Auth |
| DB hampir penuh koneksi/storage | Scale plan/pooler | Supabase |

> Atur webhook Slack/WhatsApp untuk alert kritikal. Tetapkan **on-call** sederhana (owner/dev).

## 8. Audit Bisnis (sudah ada di DB)
Stack ini sudah punya jejak audit di Postgres — manfaatkan untuk monitoring operasional:
- **Void**: `orders.voided_by`, `voided_at` (migration 035).
- **Cancel/Refund**: `orders.cancelled_by`, `cancelled_at` (045) + `cancel_reason` (047).
- **Pembayaran**: tabel `payments` (+ idempotency key).
- **Shift**: buka/tutup shift + kas.
Buat view/laporan untuk anomali (mis. void/refund berlebih per kasir).

## 9. Logging — Praktik
- Jangan log data sensitif (token, PIN, password) di klien/функции.
- Edge Functions: log terstruktur (level + konteks) — tampil di Supabase Functions logs.
- Frontend: hindari `console.log` data pelanggan di produksi.

## 10. Checklist Setup Awal
- [ ] Aktifkan Cloudflare Web Analytics (2 project).
- [ ] Aktifkan notifikasi build-failed Pages.
- [ ] Pasang health check eksternal + alert.
- [ ] Tambah Sentry/Crashlytics (mobile) & Sentry (web).
- [ ] Tinjau Supabase slow queries mingguan.
- [ ] Buat laporan anomali void/refund.
- [ ] Verifikasi backup/PITR Supabase aktif + uji restore.

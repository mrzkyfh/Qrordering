# CI/CD Pipeline — Time 420s

Strategi deploy: **Cloudflare Pages built-in Git integration** (frontend) + **Supabase CLI** (database & functions) + **Flutter** (mobile). Tanpa runner CI eksternal untuk web.

> Konteks: dipilih Cloudflare Pages built-in. GitHub Actions lama (`apps/owner-panel/.github/workflows/deploy.yml`) bersifat **opsional/legacy** — boleh dinonaktifkan agar tak ada double-deploy (lihat §6).

---

## 1. Alur Umum

```
git push (branch)
   ├─ Cloudflare Pages  → auto build & deploy (preview utk non-main, production utk main)
   └─ Supabase (manual/terpisah) → supabase db push + functions deploy
```

Frontend ter-deploy otomatis saat push. **Perubahan database & Edge Functions TIDAK otomatis** — dijalankan manual via CLI (atau workflow khusus Supabase, §5).

## 2. Frontend — Cloudflare Pages (built-in)

### owner-panel (`panel-restoran`)
Settings di Cloudflare Pages dashboard → Connect to Git → repo ini:
| Setting | Nilai |
|---------|-------|
| Production branch | `main` |
| Root directory | `apps/owner-panel` |
| Build command | `npm ci && npm run build` |
| Build output dir | `dist` |
| Node version | `20` (env `NODE_VERSION=20`) |

**Environment variables (Build & Runtime)** — set di Pages project (Production & Preview):
```
VITE_SUPABASE_URL=...
VITE_SUPABASE_ANON_KEY=...
VITE_APP_NAME=Time 420s
VITE_MENU_BASE_URL=https://times420s-menu.pages.dev
```
> ⚠️ Wajib di-set di Pages — tanpa ini build Vite menghasilkan klien Supabase tanpa kredensial (app gagal). Hanya anon key (aman di klien).

### customer-menu (project Pages terpisah)
| Setting | Nilai |
|---------|-------|
| Root directory | `apps/customer-menu` |
| Build command | `npm run build` |
| Output dir | `dist` |

`apps/customer-menu/dist/` sengaja tidak disimpan ke Git karena merupakan
artefak hasil build. Cloudflare wajib menjalankan build command di atas sebelum
memvalidasi output directory; jika build command dikosongkan, deployment akan
gagal dengan pesan `Output directory "apps/customer-menu/dist" not found`.

### Preview & Production
- Push ke `main` → **Production deploy**.
- Push ke branch lain / PR → **Preview deploy** (URL unik `*.pages.dev`).
- `apps/owner-panel/public/_redirects` → SPA fallback (semua route ke `index.html`).
- `apps/owner-panel/public/_headers` → security headers ikut ter-deploy.

## 3. Database — Supabase Migrations

Migrations berurut di `apps/supabase/migrations/NNN_*.sql` (sampai `048`).

```bash
# dari root repo (sudah login & link ke project)
supabase login
supabase link --project-ref <PROJECT_REF>
supabase db push          # apply migration yang belum jalan
```
Aturan:
- **Maju-saja**: jangan ubah migration yang sudah ter-apply; buat migration baru bernomor berikutnya.
- Apply ke **staging dulu**, verifikasi, baru production.
- Setelah perubahan view/policy, jika perlu: `NOTIFY pgrst, 'reload schema';`.

## 4. Edge Functions — Supabase

Functions aktif (Deno): `create-staff`, `clock-in`, `change-device-password`,
`change-staff-password`, `archive-orders`, dan `transaction-archive`.
```bash
supabase functions deploy create-staff --workdir apps
supabase functions deploy clock-in --workdir apps
supabase functions deploy change-device-password --workdir apps
supabase functions deploy change-staff-password --workdir apps
supabase functions deploy archive-orders --workdir apps
supabase functions deploy transaction-archive --workdir apps
# secret untuk function (mis. service_role) — JANGAN di klien:
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=... 
```

Penghapusan staff dilakukan melalui RPC database `delete_staff_user` dengan
otorisasi role, bukan melalui Edge Function publik. `archive-orders` memakai
header secret khusus dan `transaction-archive` memakai JWT/service role.

## 5. Supabase via GitHub Actions — MANUAL (workflow_dispatch)

Workflow **`.github/workflows/supabase-deploy.yml`** (root repo) sengaja **manual saja**:
jalankan dari **tab Actions → Supabase Deploy → Run workflow**. **Tidak** auto saat push,
supaya tak pernah meng-apply migration rusak ke produksi tanpa sengaja.

> Alur sehari-hari: untuk perubahan kecil tetap boleh apply SQL via **Supabase SQL Editor**.
> Workflow ini dipakai bila ingin apply migration + deploy functions sekaligus lewat CLI.

Langkah: `supabase link --workdir apps` → `db push --workdir apps` → `functions deploy --workdir apps`.
Pakai `--workdir apps` karena project Supabase berada di `apps/supabase/` (lihat `apps/supabase/config.toml`).

**Secret yang harus diset** (Repo → Settings → Secrets and variables → Actions):
| Secret | Sumber |
|--------|--------|
| `SUPABASE_ACCESS_TOKEN` | supabase.com → Account → Access Tokens |
| `SUPABASE_PROJECT_REF` | ref project (dari URL `https://<ref>.supabase.co`) |
| `SUPABASE_DB_PASSWORD` | password database project (untuk `db push`) |

> Tanpa ketiga secret ini, job akan gagal saat `link`/`db push`. Frontend tetap terpisah (Cloudflare Pages built-in).

## 6. Workflow lama (sudah dihapus)
`apps/owner-panel/.github/workflows/deploy.yml` **dihapus**. File itu berada di sub-folder (`apps/owner-panel/.github/`), sedangkan GitHub Actions hanya menjalankan workflow di **root** `.github/workflows/` — jadi sebenarnya **tidak pernah tereksekusi** (bukan sumber double-deploy). Deploy frontend memang lewat **Cloudflare Pages built-in**.

## 7. Mobile — Flutter Build & Release

```bash
cd apps/mobile/time420s
flutter pub get
flutter analyze && flutter test          # gate kualitas
# Android
flutter build apk --release              # atau appbundle utk Play Store
# iOS (perlu macOS + signing)
flutter build ipa --release
# Web (bisa ke Pages)
flutter build web --release              # output: build/web
```
- Versi di `pubspec.yaml` (`version: x.y.z+build`).
- `.env` mobile (SUPABASE URL/anon) jangan di-commit; inject saat build/CI.
- Distribusi: Play Console / App Store Connect (atau Firebase App Distribution utk internal testing).

## 8. Gerbang Kualitas (Quality Gates) — disarankan
Sebelum merge ke `main`:
- owner-panel: `npm run build` + `npx tsc --noEmit` + (lint/playwright bila ada).
- mobile: `flutter analyze` + `flutter test` (84 test saat ini).
- DB: review migration baru (cek RLS ber-scope, tidak `USING (TRUE)`).

## 9. Rollback
- **Frontend**: Cloudflare Pages → Deployments → pilih deployment lama → "Rollback".
- **DB**: jalankan migration pembalik (buat baru). Untuk insiden: restore dari backup/PITR.
- **Functions**: `supabase functions deploy` versi sebelumnya (dari git history).

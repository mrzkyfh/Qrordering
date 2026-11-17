# Environment & Secrets — Time 420s

Daftar variabel environment, lingkungan, dan pengelolaan secret untuk semua app.

> Prinsip: hanya **anon key** & URL di klien (aman, public-by-design). **`service_role`/secret sensitif hanya di server** (Supabase Edge Functions). Jangan pernah commit `.env`.

---

## 1. Variabel per Aplikasi

### owner-panel (Vite — di-embed ke bundle saat build)
| Var | Contoh | Catatan |
|-----|--------|---------|
| `VITE_SUPABASE_URL` | `https://<ref>.supabase.co` | publik |
| `VITE_SUPABASE_ANON_KEY` | `eyJ...` | anon key (publik) |
| `VITE_APP_NAME` | `Time 420s` | |
| `VITE_MENU_BASE_URL` | `https://times420s-menu.pages.dev` | base URL QR menu |

File: `apps/owner-panel/.env` (lokal, **gitignored**), `.env.example` (template, di-commit).
Di produksi/preview: set di **Cloudflare Pages → Settings → Environment variables** (lihat [CICD_PIPELINE.md](./CICD_PIPELINE.md)).

> Catatan: semua `VITE_*` **ter-embed ke bundle** → hanya untuk nilai publik. Jangan taruh secret di sini.

### customer-menu (statis)
Konfigurasi Supabase di-load di runtime (anon key/URL). Tidak ada secret. Sesuaikan nilai outlet/menu base bila ada.

### mobile (Flutter)
| Var | Catatan |
|-----|---------|
| `SUPABASE_URL` | publik |
| `SUPABASE_ANON_KEY` | anon key (publik) |
File: `apps/mobile/time420s/.env` (**gitignored**). Inject saat build/CI; jangan commit. Aset (mis. `assets/images/logo.png`) tetap di repo.

### Supabase Edge Functions (server-side secrets)
| Var | Catatan |
|-----|---------|
| `SUPABASE_SERVICE_ROLE_KEY` | **rahasia** — hak admin (create/delete staff). Hanya di function. |
| `SUPABASE_URL` | URL project |
| (lain sesuai fungsi) | mis. signing/QR |
Set via: `supabase secrets set NAMA=nilai`. **Tidak pernah** ada di klien web/mobile.

## 2. Matriks Lingkungan

| Env | owner-panel | mobile | Supabase |
|-----|-------------|--------|----------|
| **local** | `.env` lokal → `npm run dev` | `.env` lokal → `flutter run` | Supabase Cloud **atau** `supabase start` (lokal) |
| **preview** | Env "Preview" di Pages | build debug/internal | **staging** (disarankan project terpisah) |
| **production** | Env "Production" di Pages (branch `main`) | build release (store) | **production** |

> **Rekomendasi kuat**: project Supabase **staging** terpisah dari **production**, agar preview deploy & uji tidak menyentuh data live. Anon key & URL berbeda per environment.

## 3. Pengelolaan Secret — Aturan

1. **Jangan commit** `.env`/`.env.*` (kecuali `.env.example`). Sudah diperketat di `.gitignore` owner-panel; pastikan mobile juga.
2. **Klien hanya anon key.** `service_role` **eksklusif** untuk Edge Functions (`supabase secrets`).
3. **Rotasi** bila bocor: ganti anon/service key di Supabase → update env Pages + `supabase secrets` + rebuild.
   - ⚠️ Tindak lanjut audit: rotasi password owner yang pernah bocor di git (lihat `apps/owner-panel/docs/SECURITY_AUDIT.md`).
4. **Secret scanning**: aktifkan gitleaks/secret scan di repo (CI atau pre-commit).
5. **Akses minimal**: batasi siapa yang punya akses dashboard Supabase/Cloudflare.

## 4. Template `.env.example`

`apps/owner-panel/.env.example`:
```
VITE_SUPABASE_URL=https://your-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
VITE_APP_NAME=Time 420s
VITE_MENU_BASE_URL=https://times420s-menu.pages.dev
```
`apps/mobile/time420s/.env.example` (buat bila belum ada):
```
SUPABASE_URL=https://your-ref.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

## 5. Onboarding Developer (langkah cepat)
```bash
# 1. owner-panel
cd apps/owner-panel && cp .env.example .env   # isi nilai dari staging
npm ci && npm run dev

# 2. mobile
cd apps/mobile/time420s && cp .env.example .env
flutter pub get && flutter run

# 3. (opsional) DB lokal
supabase start && supabase db reset           # Docker (lihat DOCKER_SETUP.md)
```

## 6. Verifikasi `.env` aman
```bash
git check-ignore apps/owner-panel/.env        # harus: ignored
git check-ignore apps/mobile/time420s/.env    # harus: ignored
git ls-files | grep -E '\.env$'               # harus kosong
```

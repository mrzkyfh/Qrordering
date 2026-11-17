# Docker Setup — QR Ordering

## Ringkasan: produksi TIDAK memakai Docker

Stack ini **serverless/managed** (Cloudflare Pages + Supabase). Tidak ada container yang dijalankan di produksi, sehingga **tidak ada Dockerfile/K8s untuk runtime**. Ini disengaja:

| Kebutuhan | Solusi tanpa Docker |
|-----------|---------------------|
| Hosting web | Cloudflare Pages (CDN, auto-scale) |
| Backend/API | Supabase (managed Postgres + PostgREST) |
| Logic server | Supabase Edge Functions (Deno, managed) |
| Scaling | Otomatis oleh Cloudflare & Supabase |

> Menambahkan Docker/K8s di sini hanya menambah biaya & beban operasional tanpa manfaat pada skala ini.

---

## Docker dipakai untuk: **Supabase lokal (dev)**

Supabase CLI menjalankan **stack Supabase lengkap secara lokal via Docker** (Postgres, Auth, PostgREST, Studio, dll). Ini satu-satunya pemakaian Docker yang relevan.

### Prasyarat
- **Docker Desktop** (atau engine) berjalan.
- **Supabase CLI** (`brew install supabase/tap/supabase` atau npm).

### Menjalankan Supabase lokal
```bash
# dari root repo
supabase start          # menarik image & menjalankan stack (Docker)
# → tampil: API URL, anon key, service_role key, Studio URL (http://localhost:54323)

supabase db reset       # apply semua migration + seed ke DB lokal
supabase stop           # hentikan container
```
Pakai API URL & anon key lokal tersebut di `.env` app saat dev (lihat [ENVIRONMENT.md](./ENVIRONMENT.md)).

### Container yang dijalankan Supabase CLI (otomatis)
`supabase_db` (Postgres), `supabase_auth` (GoTrue), `supabase_rest` (PostgREST), `supabase_realtime`, `supabase_storage`, `supabase_studio`, `supabase_kong` (gateway). Tak perlu menulis Dockerfile — dikelola CLI.

---

## (Opsional) Containerize app web untuk dev konsisten

Bila ingin environment dev seragam (mis. onboarding tim), bisa container ringan untuk owner-panel. **Opsional**, bukan untuk produksi.

`apps/owner-panel/Dockerfile.dev` (contoh):
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host"]
```
`docker-compose.dev.yml` (contoh, root repo):
```yaml
services:
  owner-panel:
    build: { context: ./apps/owner-panel, dockerfile: Dockerfile.dev }
    ports: ["5173:5173"]
    volumes: ["./apps/owner-panel:/app", "/app/node_modules"]
    env_file: ./apps/owner-panel/.env
```
> Untuk produksi tetap pakai Cloudflare Pages (output `dist` statis); tidak perlu image produksi.

---

## Flutter & Docker
Build Flutter (terutama iOS) memerlukan toolchain native (macOS untuk iOS). **Tidak disarankan** lewat Docker untuk rilis store. Untuk CI Android bisa pakai image Flutter resmi bila diperlukan, tapi build store sebaiknya di mesin/CI ber-signing yang sesuai.

## Kesimpulan
- **Produksi**: tanpa Docker (serverless). ✅
- **Dev DB lokal**: Docker via `supabase start` (managed CLI). ✅
- **Dev app dalam container**: opsional (contoh di atas).

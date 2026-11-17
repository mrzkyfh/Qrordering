# Deploy QR Ordering ke Cloudflare Workers

Gunakan repository `mrzkyfh/Qrordering`, branch `main`, dan akun Cloudflare dengan account ID `878f8c8e93d296085a23e091307a5f9c`.

## Dua project dari repo yang sama

| Pengaturan | Panel | Menu pelanggan |
|---|---|---|
| Worker name | `qrordering` | `qrordering-menu` |
| Root directory | `apps/owner-panel` | `apps/customer-menu` |
| Production branch | `main` | `main` |
| Build command | `npm ci && npm run build` | `npm ci && npm run build` |
| Deploy command | `npx wrangler deploy` | `npx wrangler deploy` |
| Node version | `24` | `24` |

Jika pilihan root directory tidak tersedia, jalankan dari root repository:

- Panel: `cd apps/owner-panel && npm ci && npm run build`
- Menu: `cd apps/customer-menu && npm ci && npm run build`

Gunakan deploy command dengan pola folder yang sama.

## Build variables panel

Masukkan ke **Settings → Builds → Variables and secrets** sebelum build pertama:

| Variable | Nilai |
|---|---|
| `VITE_SUPABASE_URL` | `https://yjmrabgpxjbunwtsiavs.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Publishable/anon key proyek Supabase baru |
| `VITE_SUPABASE_FALLBACK_URL` | `https://api.qrordering.my.id` |
| `VITE_MENU_BASE_URL` | `https://menu.qrordering.my.id` |
| `VITE_IMAGE_STORAGE_BACKEND` | `r2-production` |
| `VITE_R2_API_URL` | URL Worker R2 produksi QR Ordering |
| `NODE_VERSION` | `24` |

Jangan memasukkan service-role key ke build frontend.

## Domain yang perlu disiapkan

- Panel: `https://qrordering.my.id`
- Menu pelanggan: `https://menu.qrordering.my.id`
- Gateway API: `https://api.qrordering.my.id`
- Aset: `https://assets.qrordering.my.id`

Domain tersebut harus dibuat dan diarahkan ke Worker baru sebelum dipakai sebagai URL produksi. Sampai DNS siap, gunakan URL `workers.dev` yang diberikan Cloudflare.

## Verifikasi

1. Buka panel dan refresh halaman `/admin`.
2. Pastikan variabel Supabase tersedia pada build produksi.
3. Buat atau regenerate QR setelah `VITE_MENU_BASE_URL` mengarah ke menu pelanggan baru.
4. Pindai QR dan pastikan token meja aktif ditemukan di Supabase baru.
5. Jangan menggunakan QR lama karena tokennya berasal dari environment sebelumnya.

## Deploy manual

Jalankan dari folder aplikasi:

```sh
npm ci
npm run build
npx wrangler deploy
```

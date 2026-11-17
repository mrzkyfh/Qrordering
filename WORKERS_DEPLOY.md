# Deploy Time420S ke Cloudflare Workers

Kode siap untuk Workers; deployment dilakukan di akun baru tanpa menghapus deployment lama. Pages lama masih aktif sebagai rollback. Gunakan repo `official655/Time420s`, branch `main`, akun Cloudflare `Official@clegagroup.com` (`b0d09d15b16ea37156b38470fd58350d`).

## Dua project dari repo yang sama

Di Cloudflare Workers & Pages, buat Worker dengan **Import a repository / Connect GitHub**, izinkan akses ke `official655/Time420s`. Buat dua project dengan pengaturan berikut:

| Pengaturan | Panel | Menu pelanggan |
|---|---|---|
| Worker name | `time420s` | `times420s-menu` |
| Root directory | `apps/owner-panel` | `apps/customer-menu` |
| Production branch | `main` | `main` |
| Build command | `npm ci && npm run build` | `npm ci && npm run build` |
| Deploy command | `npx wrangler deploy` | `npx wrangler deploy` |
| Node version | `24` | `24` |

Konfigurasi `assets.directory = "./dist"` sudah ada di masing-masing `wrangler.toml`. Jangan memakai perintah `wrangler pages deploy`. Nonaktifkan build branch non-production selama setup awal agar URL preview tidak memerlukan tambahan izin CORS.

## Build variables panel

Masukkan ke **Settings → Builds → Variables and secrets**, sebelum build pertama. Variabel GitHub Actions tidak otomatis tersedia di Workers Builds.

| Variable | Nilai |
|---|---|
| `VITE_SUPABASE_URL` | `https://jstdtalbihxlbpfsisab.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Anon key proyek baru, salin dari `.env` lokal salinan migrasi |
| `VITE_SUPABASE_FALLBACK_URL` | `https://api.time420s.my.id` |
| `VITE_MENU_BASE_URL` | `https://menu.time420s.my.id` |
| `VITE_IMAGE_STORAGE_BACKEND` | `r2-production` |
| `VITE_R2_API_URL` | `https://time420s-r2-production.official-b0d.workers.dev` |
| `NODE_VERSION` | `24` |

Menu sudah menggunakan URL dan anon key publik proyek baru. Jangan memasukkan service-role key ke build frontend.

## Alamat yang disiapkan

Berdasarkan subdomain Workers akun yang sudah digunakan gateway:

- Panel: `https://time420s.my.id`
- Menu: `https://menu.time420s.my.id`

Ketiga domain kustom sudah dipasang di Worker masing-masing: panel pada domain utama, menu pada subdomain `menu`, dan gateway pada subdomain `api`.

## Backend setelah deploy web

Kode CORS Supabase dan konfigurasi gateway menambahkan domain kustom sambil mempertahankan alamat lama selama masa transisi:

```sh
# Dari root repo tujuan; pastikan login akun Supabase yang benar.
supabase functions deploy --project-ref jstdtalbihxlbpfsisab --workdir apps

# Jika gateway cadangan tetap digunakan:
cd apps/network-gateway
npm ci
npm run deploy
```

Upload gambar baru memakai Worker R2 produksi dan URL publik
`https://assets.time420s.my.id`. Supabase Auth, Database, dan Realtime tetap
digunakan. URL gambar Supabase lama tetap didukung untuk rollback dan jangan
dihapus hanya karena database sudah menunjuk ke R2.

Sebelum push ke branch `main`, verifikasi kedua build variable R2 di atas masih
tersimpan pada konfigurasi Workers Builds. Push `main` dapat memicu build dan
deployment otomatis untuk panel dan menu pelanggan bila koneksi GitHub aktif.

## Verifikasi sebelum beralih

1. Buka panel dan refresh halaman `/admin`; halaman aplikasi harus tampil.
2. Pastikan file `/assets/tidak-ada.js` menghasilkan 404 dan `Cache-Control: no-store`, bukan HTML.
3. Buat akun owner ketika siap; uji login, menu, upload gambar, dan fungsi pengelolaan staf.
4. Buat QR dari panel dan pastikan menuju domain menu Workers.
5. Build ulang mobile untuk link panel baru. Jangan hapus Pages lama sebelum semua pemeriksaan selesai.

## Deploy manual dari terminal (alternatif)

Jalankan dari folder masing-masing aplikasi:

```sh
npm ci
npm run check:worker  # build + dry-run, tidak upload
npm run deploy       # build + deploy sungguhan
```

Tidak ada workflow GitHub Actions yang otomatis men-deploy Pages. Push hanya memicu Workers Builds setelah kamu menghubungkan project di Cloudflare.

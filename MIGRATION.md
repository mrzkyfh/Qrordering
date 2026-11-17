# Time420S — promosi staging ke production

- GitHub: https://github.com/official655/Time420s
- Cloudflare account ID: `b0d09d15b16ea37156b38470fd58350d`
- Panel sementara: https://time420s-staging.official-b0d.workers.dev
- Menu pelanggan sementara: https://time420s-menu-staging.official-b0d.workers.dev
- Gateway sementara: https://time420s-network-gateway-staging.official-b0d.workers.dev
- Assets sementara: https://time420s-r2-staging.official-b0d.workers.dev
- Supabase: https://jstdtalbihxlbpfsisab.supabase.co

## Data dan penyimpanan

Project Supabase yang sama tetap digunakan sehingga akun, outlet, dan transaksi
tidak dipindahkan. Gambar baru memakai R2 bucket `time420s-assets-staging` melalui
Worker `time420s-r2-staging`. Resource tersebut sudah diuji di staging dan
dipromosikan in-place menjadi production; nama dipertahankan untuk menghindari
perubahan binding, URL, dan object.

## Deployment

Target frontend adalah **Cloudflare Workers Static Assets** dan terhubung ke
branch `main` repo baru. Domain production belum dipindahkan. Sampai cutover,
resource lama dan DNS lama harus tetap aktif sebagai jalur rollback.

Konfigurasi panel dan mobile tersimpan di `.env` lokal dan tidak di-commit. APK
lama tetap memakai backend/link yang tertanam pada build sebelumnya.

## Validasi

- Staging panel, gateway, R2 Worker, dan upload gambar sudah berfungsi.
- 110 object yang direferensikan database sudah dicopy ke bucket promosi;
  97 disalin dan diverifikasi checksum, 13 sudah ada dari pengujian sebelumnya.
- Domain production belum dipindahkan.
- Resource lama belum dihapus atau dimatikan.

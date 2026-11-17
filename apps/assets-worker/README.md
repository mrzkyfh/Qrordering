# Time420s Assets Worker

Penyimpanan khusus gambar Time420s di Cloudflare R2. Database, autentikasi,
transaksi, dan konfigurasi tetap berada di Supabase.

## Production

Konfigurasi produksi berada di `wrangler.toml`:

- Worker: `time420s-r2-production`
- Bucket: `time420s-assets`
- URL publik: `https://assets.time420s.my.id`

Simpan anon key Supabase sebagai secret Worker:
   `npx wrangler secret put SUPABASE_ANON_KEY`.
Jangan menyimpan nilai secret di repository.

Upload dan delete hanya menerima sesi Supabase aktif dengan role owner/admin.
Pembacaan `/assets/*` bersifat publik karena gambar menu memang ditampilkan di
web pemesanan tanpa login.

## Staging

Konfigurasi staging terpisah berada di `wrangler.staging.toml`. Jangan memakai
file staging untuk deploy produksi dan jangan mengikat Worker produksi ke bucket
`time420s-assets-staging`.

## Penghapusan data

Bucket R2 berada di luar database Supabase. Sebelum menjalankan
`apps/supabase/seeds/reset_all_data_keep_owner.sql`:

1. Buka Cloudflare Dashboard → R2 Object Storage → bucket environment yang benar.
2. Pastikan backup yang diperlukan sudah tersedia.
3. Hapus seluruh object di dalam bucket, tetapi pertahankan bucket dan binding
   `IMAGES` agar Assets Worker tetap dapat menerima unggahan baru.
4. Pastikan bucket menunjukkan 0 object.
5. Isi konfirmasi R2 pada SQL factory reset, lalu jalankan SQL melalui Supabase
   SQL Editor.

Jangan menghapus bucket produksi `time420s-assets` karena deployment Worker
bergantung pada binding tersebut. SQL Supabase tidak dapat memeriksa atau
menghapus object Cloudflare R2 secara otomatis.

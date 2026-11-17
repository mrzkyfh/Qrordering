# Time420s Network Gateway

Jalur cadangan terbatas untuk aplikasi Time420s ketika jaringan pelanggan
tidak dapat menjangkau domain Supabase secara langsung.

- Gateway hanya meneruskan path Supabase yang telah diizinkan.
- Gateway tidak menyimpan service-role key, token, atau isi transaksi.
- RLS dan autentikasi tetap diperiksa oleh Supabase.
- Aplikasi tetap mengutamakan koneksi langsung dan memakai gateway hanya
  ketika pemeriksaan koneksi langsung gagal.

Validasi dan deploy:

```bash
npm run check
npm run deploy
```

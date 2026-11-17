# Negative Test Report — Owner Panel

- **Tanggal:** 2026-06-05 · **Scope:** `apps/owner-panel` + RPC/Edge Functions/RLS yang dipakainya.
- **Tester:** QA Engineer
- **Metode:** Telaah guard nyata (RLS, CHECK, validasi RPC, otorisasi Edge Function) + skenario input/akses tidak valid — termasuk **bypass UI** (panggil API langsung), karena validasi klien (zod) bukan kontrol keamanan.
- **Pertanyaan:** "Adakah negative case owner-panel yang **lolos**?"

**Verdict:** Banyak guard solid. **3 gap** ditemukan, semua di **manajemen staff (delete-staff)** & assignment — bukan validasi field, melainkan **otorisasi target**.

---

## 1. Negative case yang DITOLAK (PASS)

| Fitur | Negative case | Penjaga | Hasil |
|-------|---------------|---------|-------|
| Auth | Akses halaman tanpa login | `ProtectedRoute` + RLS | ✅ |
| Auth | Role admin akses route owner | `allowedRoles` + redirect | ✅ (UX); data tetap RLS |
| Multi-tenant | Admin baca/tulis data outlet lain | RLS scope `outlet_id` (005, **048**) | ✅ *(syarat 048 ter-apply)* |
| Menu | Harga < 0 | `CHECK price>=0` (002/022) | ✅ |
| Menu | Upload gambar > 5 MB / tipe salah (bypass cek klien) | bucket `file_size_limit`+`allowed_mime_types` (006) | ✅ server-enforced |
| Menu | Hapus menu yang sudah pernah dipesan | smart-delete → **arsip** (037) | ✅ transaksi aman |
| Kategori | Hapus kategori berisi item | `menu_items.category_id` `SET NULL` | ✅ item jadi tanpa kategori |
| Meja | Hapus meja yang dipakai order | `orders.table_id` `SET NULL` | ✅ order utuh |
| Promo | Persentase di luar 0–100 / tanggal mulai>akhir | `chk_promo_percentage_range`, `chk_promo_date_range` (022) | ✅ |
| Promo | usage_count > usage_limit | `CHECK` (025) | ✅ |
| Voucher | Kode kedaluwarsa/nonaktif/lewat batas | `validate_promo_code` RAISE (040) | ✅ |
| Loyalty | Adjust poin → saldo negatif | `chk_points_non_negative` (018) | ✅ |
| Loyalty | Hapus member | `loyalty_transactions` CASCADE, `orders.loyalty_member_id` SET NULL | ✅ order utuh |
| Outlet | Nama < 2 / > 100 char | `CHECK char_length` (021) | ✅ |
| Outlet | **Admin** hapus outlet | `outlets_delete` = `is_owner()` saja (005) | ✅ admin ditolak |
| Expense | Tanggal masa depan | `CHECK expense_date<=CURRENT_DATE` (022) | ✅ |
| Shift | Kas awal negatif | `CHECK opening_cash>=0` (025) | ✅ |
| Staff | Buat staff oleh **non-owner** | create-staff cek `role='owner'` → 403 | ✅ |
| Staff | Role tidak valid (mis. 'superadmin') | kolom `role` tipe ENUM `user_role` → ditolak | ✅ |
| Pencarian | Injection di filter `.or()` | `sanitizeSearch` | ✅ |
| Storage | Hapus file gambar saat hapus menu | await + error toast | ✅ (gagal kini terlihat) |

---

## 2. Negative case yang LOLOS (gap) ⚠️

> Semua gap memerlukan **bypass UI** (panggil Edge Function langsung dengan token sah). UI normal mungkin tak menampilkannya, tapi kontrolnya **tidak ditegakkan di server**.

### OG1 — `delete-staff`: admin bisa hapus **owner** / staff **outlet lain** *(Medium-High)*
**Skenario:** Admin outlet A memanggil `delete-staff` dengan `user_id` milik **owner**, atau staff **outlet B**.
**Lolos:** Function hanya memverifikasi **caller** ber-role `owner`/`admin` — **tidak** memeriksa siapa **target**-nya (role/outlet). Penghapusan pakai `service_role` (bypass RLS). Jadi admin dapat menghapus owner atau staf lintas-outlet.
**Lokasi:** `apps/supabase/functions/delete-staff/index.ts` (cek caller saja, baris ~52).
**Rekomendasi:**
- Ambil profil **target**; tolak bila:
  - target ber-role `owner` dan caller bukan `owner`;
  - `target.outlet_id != caller.outlet_id` saat caller `admin` (admin hanya outletnya).
- Batasi admin hanya boleh menghapus `kasir`/`dapur`.

### OG2 — `delete-staff`: bisa hapus **diri sendiri** / **owner terakhir** *(Medium)*
**Skenario:** Owner menghapus akunnya sendiri, atau owner terakhir di outlet.
**Lolos:** Tak ada pengecekan self-delete / "owner terakhir" → risiko **lockout** (tak ada yang bisa kelola outlet).
**Rekomendasi:** Tolak `user_id == caller.id`; tolak bila target owner terakhir untuk outlet tsb.

### OG3 — `create-staff`: assign **outlet/role** tanpa batas kepemilikan *(Medium)*
**Skenario:** Owner X membuat staff dengan `outlet_id` milik **owner Y**, atau memberi role `owner` ke staff baru.
**Lolos:** Function tak memverifikasi `outlet_id` benar-benar milik caller. (Role valid karena ENUM, tapi pemberian `owner` & outlet lintas-pemilik tak dibatasi.)
**Lokasi:** `apps/supabase/functions/create-staff/index.ts` (upsert profile pakai `outlet_id`/`role` apa adanya, baris ~61).
**Rekomendasi:** Validasi `outlet_id` ada di daftar outlet milik caller; batasi role yang boleh diberikan (mis. owner hanya boleh buat `admin`/`kasir`/`dapur`, bukan `owner` lain) sesuai kebijakan.

---

## 3. Catatan
- Guard di §1 banyak **bergantung migrasi ter-apply** (terutama **048** RLS scope). Jika DB produksi belum di-`db push`, beberapa baris "PASS" bisa berubah jadi lolos — **verifikasi di DB target**.
- Validasi form (zod) di klien **tidak** dihitung sebagai kontrol; yang menentukan adalah guard **DB / RPC / Edge Function**.

## 4. Prioritas Perbaikan (owner-panel)
1. **OG1** — `delete-staff` cek role & outlet target.
2. **OG2** — cegah self-delete / hapus owner terakhir.
3. **OG3** — `create-staff` validasi kepemilikan outlet + batasi role.

> Catatan: negative-case **mobile** (PIN void/refund client-side & rate-limit, validasi nominal bayar, spam self-order) ditunda sesuai permintaan — akan dibuat laporan terpisah nanti.

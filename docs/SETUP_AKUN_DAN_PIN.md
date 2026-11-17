# Panduan Setup Akun, PIN & Login — QrOrdering

Panduan **praktis langkah-demi-langkah** untuk menyiapkan akun, PIN, dan login.
Untuk detail hak akses per role, lihat [ROLE_DAN_HAK_AKSES.md](ROLE_DAN_HAK_AKSES.md).

> Panduan ini menjawab masalah yang sering muncul saat pertama pakai:
> *"owner belum ada PIN"*, *"akun belum terhubung ke outlet"*, *"owner tak bisa
> atur PIN dari HP"*, dan *"kas cuma bisa diisi kasir"*.

---

## 1. Tiga jenis akun (WAJIB paham dulu)

| Jenis | Cara login | Dibuat di mana | Fungsi |
|-------|-----------|----------------|--------|
| **Owner** | Email + password (web) | **Manual di Supabase** (dashboard) — akun pertama | Kuasa penuh, semua cabang. Punya akses web. |
| **Akun Perangkat** (cabang) | Email + password (di tablet, **1×**) | Owner-panel web → **Manajemen Staff → Akun Perangkat** | "Gerbang" login tablet kasir per cabang. Role dipaksa `pelanggan`, **tak muncul** di daftar clock-in. |
| **Staf** (admin/manajer/kasir) | **PIN 4 digit** (clock-in) | Owner-panel web → **Manajemen Staff → Tambah Staf** | Operator harian. Admin/manajer **opsional** dapat email+password untuk akses web. |

**Inti model:** tablet login **sekali** pakai *Akun Perangkat*, lalu tiap staf
tinggal **pilih nama + PIN** (clock-in). Tak perlu email/password per orang di HP.

---

## 2. Urutan setup pertama kali

1. **Buat owner** di Supabase dashboard (Authentication → Add user): email + password.
   Pastikan ada baris di tabel `profiles` dengan `role = 'owner'`.
2. **Owner login ke owner-panel web** pakai email+password itu.
3. **Buat outlet** (cabang) di web.
4. **Buat Akun Perangkat** per cabang: Manajemen Staff → **Akun Perangkat** →
   isi email + password (min 8 karakter) + pilih cabang.
5. **Buat staf** (kasir/manajer/admin): Manajemen Staff → Tambah Staf →
   nama + role + **PIN 4 digit** + cabang. (Admin/manajer: isi email+password
   bila perlu akses web.)
6. **Owner set PIN sendiri** (untuk clock-in): Manajemen Staff → baris owner →
   **Atur PIN** → isi 4 digit. *(Owner tak wajib clock-in untuk kerja di web,
   tapi butuh PIN kalau mau operasikan kasir di tablet.)*
7. **Di tablet:** buka app → login **Akun Perangkat** (email+password cabang) →
   layar clock-in → **pilih nama + masukkan PIN**.

---

## 3. Set / reset PIN

- **Selalu dari owner-panel WEB** → Manajemen Staff → tombol **Atur PIN** di baris staf.
- **PIN TIDAK bisa dibuat dari layar clock-in mobile** (di layar itu kamu = akun
  perangkat, bukan staf individual).
- **Aturan (siapa boleh atur PIN siapa):** tiap role boleh atur PIN **level sendiri
  ke bawah**, dan **PIN sendiri selalu boleh**:
  - Owner → owner, admin, manajer, kasir
  - Admin → admin, manajer, kasir
  - Manajer → manajer, kasir
  - Kasir → kasir
- **5× PIN salah** saat clock-in/approval → terkunci **5 menit** (anti brute-force).

---

## 4. Login di tablet kasir (harian)

1. (Sekali saat setup device) Login **Akun Perangkat**: email + password cabang.
2. Muncul layar **clock-in**: pilih nama staf → masukkan **PIN 4 digit**.
3. Masuk ke antarmuka **Kasir** (semua role masuk ke sini — mobile = POS murni).
4. **Ganti staf** (shift ganti orang): menu → **Keluar** (clock-out) → pilih nama lain.
5. **Ganti/lepas perangkat**: butuh login Akun Perangkat lagi (gerbang keamanan).

---

## 5. Troubleshooting (masalah umum)

### ❓ "Belum ada PIN" saat pilih nama di clock-in
Staf itu belum punya PIN. **Solusi:** owner/atasan buka **owner-panel web →
Manajemen Staff → Atur PIN** untuk staf tsb. Lalu clock-in lagi.

### ❓ "Akun ini belum terhubung ke outlet" di layar Kasir
Terjadi pada staf tanpa outlet sendiri (mis. **owner multi-cabang**). Sistem
otomatis memakai **outlet dari Akun Perangkat** tempat clock-in. Bila masih error:
pastikan **Akun Perangkat sudah dipilih cabangnya** saat dibuat.

### ❓ Owner tak bisa atur PIN dari HP
Memang tidak bisa dari clock-in. **Owner atur PIN dari WEB** (owner-panel →
Manajemen Staff → Atur PIN pada baris owner). Owner sudah punya akses web sejak
dibuat (email+password).

### ❓ Menu "Tutup Kasir" / kas tidak muncul untuk admin/manajer/owner
**By design.** Kas & tutup shift **hanya untuk role Kasir**. Admin/manajer/owner
tetap bisa transaksi, tapi tak mengisi kas. *(Penjualan tunai mereka otomatis
nempel ke shift kasir yang sedang buka di till itu.)*

### ❓ Order self-order (web) tak bunyi / tak auto-print di tablet
Notifikasi & auto-print tiket dapur aktif untuk **owner/kasir/admin/manajer**
yang sedang clock-in. Pastikan tablet **online** dan printer dapur ter-set
(Pengaturan → Perangkat).

---

## 6. Catatan penting

- **Owner tidak bisa dibuat dari aplikasi** (hanya via Supabase dashboard) — ini
  sengaja, karena owner adalah akun teratas.
- **Mobile = POS murni** untuk semua role. Manajemen (produk, staf, laporan
  lengkap, supplier, dll) **lewat owner-panel web**.
- **1 outlet diasumsikan 1 till** (1 shift kasir aktif). Bila butuh >1 till
  bersamaan per outlet, konsultasikan — atribusi kas perlu penyesuaian.

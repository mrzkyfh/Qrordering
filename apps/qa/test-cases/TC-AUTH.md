# Test Cases — Authentication
**Module:** Authentication  
**Aplikasi:** Owner Panel

---

## TC-AUTH-001 — Login berhasil sebagai Owner

| Field | Detail |
|-------|--------|
| **Priority** | Critical |
| **Precondition** | Akun owner sudah terdaftar di Supabase, browser sudah dibuka |

**Steps:**
1. Buka halaman login Owner Panel
2. Masukkan email owner yang valid
3. Masukkan password yang benar
4. Klik tombol **Login**

**Expected Result:**
- Berhasil masuk ke dashboard
- Semua menu navigasi untuk role **owner** terlihat (termasuk menu yang restricted untuk kasir)
- Nama/email user tampil di header

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-AUTH-002 — Login berhasil sebagai Kasir

| Field | Detail |
|-------|--------|
| **Priority** | Critical |
| **Precondition** | Akun kasir sudah terdaftar dan aktif |

**Steps:**
1. Buka halaman login Owner Panel
2. Masukkan email kasir yang valid
3. Masukkan password yang benar
4. Klik tombol **Login**

**Expected Result:**
- Berhasil masuk ke dashboard
- Menu navigasi yang muncul **hanya** yang diperbolehkan untuk role kasir
- Menu owner-only (seperti laporan keuangan, manajemen user) tidak terlihat atau tidak bisa diakses

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-AUTH-003 — Login gagal dengan password salah

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Browser sudah dibuka, belum login |

**Steps:**
1. Buka halaman login Owner Panel
2. Masukkan email yang valid
3. Masukkan password yang **salah**: `wrongpassword123`
4. Klik tombol **Login**

**Expected Result:**
- Login gagal
- Muncul pesan error yang jelas (contoh: *"Email atau password salah"*)
- Tetap berada di halaman login
- Password field dikosongkan

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-AUTH-004 — Login dengan email tidak terdaftar

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Browser sudah dibuka, belum login |

**Steps:**
1. Buka halaman login
2. Masukkan email yang belum pernah didaftarkan: `tidakada@email.com`
3. Masukkan password apapun: `password123`
4. Klik tombol **Login**

**Expected Result:**
- Login gagal
- Muncul pesan error yang sesuai
- Tidak memberikan informasi apakah email atau password yang salah (untuk keamanan)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-AUTH-005 — Login dengan field kosong

| Field | Detail |
|-------|--------|
| **Priority** | Medium |
| **Precondition** | Browser sudah dibuka, belum login |

**Steps:**
1. Buka halaman login
2. Biarkan field email **kosong**
3. Biarkan field password **kosong**
4. Klik tombol **Login**

**Expected Result:**
- Login tidak diproses
- Muncul validasi error pada field yang kosong
- Tombol Login mungkin disabled atau muncul pesan "field wajib diisi"

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-AUTH-006 — Logout berhasil

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | User sudah login |

**Steps:**
1. Dari halaman dashboard (setelah login)
2. Klik menu/tombol **Logout** (biasanya di pojok kanan atas atau sidebar)
3. Perhatikan apa yang terjadi

**Expected Result:**
- User berhasil logout
- Diarahkan kembali ke halaman login
- Jika mencoba akses URL dashboard secara langsung → diarahkan ke halaman login (session sudah bersih)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

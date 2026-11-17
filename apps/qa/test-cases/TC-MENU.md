# Test Cases — Menu Management
**Module:** Menu Management  
**Aplikasi:** Owner Panel  
**Precondition umum:** Login sebagai owner, sudah ada minimal 1 kategori

---

## TC-MENU-001 — Tambah kategori menu baru

| Field | Detail |
|-------|--------|
| **Priority** | High |

**Steps:**
1. Buka halaman Manajemen Menu
2. Klik **Tambah Kategori**
3. Isi nama: `Minuman Panas`
4. Simpan

**Expected Result:**
- Kategori baru muncul di daftar
- Nama tampil sesuai yang diinput

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-002 — Tambah menu item baru

| Field | Detail |
|-------|--------|
| **Priority** | Critical |

**Steps:**
1. Buka halaman Manajemen Menu
2. Klik **Tambah Item**
3. Isi nama: `Kopi Susu`
4. Pilih kategori: `Minuman Panas`
5. Isi harga: `25000`
6. Pastikan toggle **Tersedia** aktif
7. Simpan

**Expected Result:**
- Item berhasil tersimpan
- Muncul di daftar menu dengan harga Rp 25.000
- Item tampil di Customer Menu (di bawah kategori Minuman Panas)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-003 — Edit harga menu item

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Menu item sudah ada |

**Steps:**
1. Cari item `Kopi Susu` di daftar menu
2. Klik **Edit**
3. Ubah harga dari `25000` menjadi `28000`
4. Simpan

**Expected Result:**
- Harga berhasil diperbarui menjadi Rp 28.000
- Harga baru langsung tampil di daftar menu
- Order baru yang dibuat setelah perubahan ini menggunakan harga baru

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-004 — Nonaktifkan menu item (tidak tersedia)

| Field | Detail |
|-------|--------|
| **Priority** | High |

**Steps:**
1. Buka detail/edit menu item `Kopi Susu`
2. Toggle **Tersedia** → OFF (tidak tersedia)
3. Simpan

**Expected Result:**
- Item ditandai sebagai tidak tersedia
- Di Customer Menu, item tidak bisa dipilih atau tampil dengan label "Habis"
- Di Owner Panel, item masih terlihat tapi dengan indikator tidak aktif

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-005 — Tambah menu dengan harga 0

| Field | Detail |
|-------|--------|
| **Priority** | Medium |
| **Tipe** | Negative / Boundary |

**Steps:**
1. Tambah menu item baru
2. Isi nama: `Air Putih`
3. Isi harga: `0`
4. Simpan

**Expected Result:**
- Sistem memperbolehkan harga 0 (karena di schema: `price >= 0`)
- Item tersimpan dengan harga Rp 0
- Atau muncul konfirmasi "Apakah yakin harga 0?"

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-006 — Tambah menu tanpa nama

| Field | Detail |
|-------|--------|
| **Priority** | Medium |
| **Tipe** | Negative |

**Steps:**
1. Tambah menu item baru
2. Kosongkan field nama
3. Isi harga: `15000`
4. Klik Simpan

**Expected Result:**
- Sistem menolak penyimpanan
- Muncul validasi error: "Nama menu wajib diisi"

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-007 — Hapus menu item

| Field | Detail |
|-------|--------|
| **Priority** | Medium |

**Steps:**
1. Pilih menu item yang tidak terkait dengan order aktif
2. Klik **Hapus**
3. Konfirmasi penghapusan

**Expected Result:**
- Muncul dialog konfirmasi sebelum dihapus
- Setelah dikonfirmasi, item hilang dari daftar
- Item tidak lagi muncul di Customer Menu

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-MENU-008 — Upload gambar menu item

| Field | Detail |
|-------|--------|
| **Priority** | Low |

**Steps:**
1. Edit menu item manapun
2. Upload gambar (format JPG/PNG, ukuran < 2MB)
3. Simpan

**Expected Result:**
- Gambar berhasil diupload ke Supabase Storage
- Gambar tampil di preview menu item
- Gambar tampil di Customer Menu

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

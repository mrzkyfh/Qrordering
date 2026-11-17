# Test Cases — Order Management
**Module:** Order Management  
**Aplikasi:** Owner Panel  
**Precondition umum:** User sudah login, shift kasir sudah dibuka, menu sudah tersedia

---

## TC-ORDER-001 — Buat order baru (Dine In)

| Field | Detail |
|-------|--------|
| **Priority** | Critical |

**Steps:**
1. Buka halaman POS / buat order baru
2. Pilih tipe order: **Dine In**
3. Pilih nomor meja (contoh: Meja 5)
4. Tambahkan minimal 2 menu item berbeda
5. Klik **Buat Order** atau **Konfirmasi**

**Expected Result:**
- Order berhasil dibuat dengan status `draft` atau `pending`
- Order number ter-generate otomatis (unik)
- Subtotal dihitung dengan benar sesuai harga × qty
- Meja yang dipilih berubah status menjadi `occupied`

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-002 — Buat order (Takeaway)

| Field | Detail |
|-------|--------|
| **Priority** | High |

**Steps:**
1. Buat order baru
2. Pilih tipe order: **Takeaway**
3. Isi nama customer (opsional)
4. Tambahkan item menu
5. Konfirmasi order

**Expected Result:**
- Order berhasil dibuat dengan order_type = `takeaway`
- Tidak perlu memilih meja
- Customer name tersimpan (jika diisi)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-003 — Tambah item ke order yang sudah ada

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Order dengan status `pending` sudah ada |

**Steps:**
1. Buka order yang sudah ada (status pending/open)
2. Tambahkan 1 item menu baru ke order tersebut
3. Simpan perubahan

**Expected Result:**
- Item berhasil ditambahkan ke order
- Subtotal dan total_amount diperbarui secara otomatis
- Item baru muncul di daftar order items

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-004 — Ubah quantity item dalam order

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Order dengan minimal 1 item sudah ada |

**Steps:**
1. Buka order yang aktif
2. Ubah quantity salah satu item dari 1 menjadi 3
3. Simpan perubahan

**Expected Result:**
- Quantity item berubah menjadi 3
- Subtotal item = harga × 3
- Total order diperbarui dengan benar

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-005 — Hapus item dari order

| Field | Detail |
|-------|--------|
| **Priority** | Medium |
| **Precondition** | Order dengan minimal 2 item sudah ada |

**Steps:**
1. Buka order yang aktif
2. Hapus salah satu item dari order
3. Konfirmasi penghapusan (jika ada dialog konfirmasi)

**Expected Result:**
- Item berhasil dihapus dari daftar
- Total order diperbarui (berkurang sesuai harga item yang dihapus)
- Jika item terakhir dihapus → muncul konfirmasi atau warning

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-006 — Update status order ke "served"

| Field | Detail |
|-------|--------|
| **Priority** | High |
| **Precondition** | Order dengan status `pending` sudah ada |

**Steps:**
1. Buka order yang sedang berjalan
2. Ubah status menjadi **Served** (sudah disajikan)
3. Simpan

**Expected Result:**
- Status order berubah menjadi `served`
- Timestamp update tercatat
- Terlihat di daftar order dengan status yang benar

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-ORDER-007 — Hitung pajak dan service charge secara otomatis

| Field | Detail |
|-------|--------|
| **Priority** | Critical |

**Steps:**
1. Buat order baru
2. Tambahkan item dengan harga Rp 100.000
3. Lihat rincian total di halaman order

**Expected Result:**
- Tax (11%) = Rp 11.000
- Service charge (5%) = Rp 5.000
- Total = Rp 100.000 + Rp 11.000 + Rp 5.000 = **Rp 116.000**
- Angka di UI sesuai perhitungan (tidak ada pembulatan yang salah)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

# Test Cases — Payment
**Module:** Payment  
**Aplikasi:** Owner Panel  
**Precondition umum:** User login sebagai kasir, order sudah siap dibayar (status served/pending)

---

## TC-PAY-001 — Bayar tunai dengan uang pas

| Field | Detail |
|-------|--------|
| **Priority** | Critical |

**Steps:**
1. Buka order yang siap dibayar (total misalnya Rp 116.000)
2. Pilih metode pembayaran: **Tunai**
3. Masukkan jumlah uang yang diterima: `116000`
4. Proses pembayaran

**Expected Result:**
- Pembayaran berhasil dicatat
- Kembalian = Rp 0
- Status order berubah menjadi `completed` atau `paid`
- Muncul struk / ringkasan pembayaran

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-PAY-002 — Bayar tunai dengan uang lebih (ada kembalian)

| Field | Detail |
|-------|--------|
| **Priority** | Critical |

**Steps:**
1. Buka order dengan total Rp 116.000
2. Pilih metode: **Tunai**
3. Masukkan jumlah uang: `150000`
4. Proses pembayaran

**Expected Result:**
- Kembalian = Rp 34.000 ditampilkan dengan jelas
- Pembayaran berhasil
- Tidak ada error meski uang melebihi total

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-PAY-003 — Bayar tunai dengan uang kurang

| Field | Detail |
|-------|--------|
| **Priority** | High |

**Steps:**
1. Buka order dengan total Rp 116.000
2. Pilih metode: **Tunai**
3. Masukkan jumlah uang: `50000` (kurang dari total)
4. Coba proses pembayaran

**Expected Result:**
- Sistem **tidak memproses** pembayaran
- Muncul pesan error atau warning bahwa uang tidak cukup
- Tombol bayar disabled atau validasi mencegah submit

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-PAY-004 — Bayar dengan QRIS

| Field | Detail |
|-------|--------|
| **Priority** | High |

**Steps:**
1. Buka order yang siap dibayar
2. Pilih metode pembayaran: **QRIS**
3. (Jika ada) masukkan reference number dari bukti transfer
4. Proses pembayaran

**Expected Result:**
- Pembayaran berhasil dicatat dengan method = `qris`
- Status order berubah menjadi paid/completed
- Reference number tersimpan (jika diisi)

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

---

## TC-PAY-005 — Bayar dengan Transfer Bank

| Field | Detail |
|-------|--------|
| **Priority** | Medium |

**Steps:**
1. Buka order yang siap dibayar
2. Pilih metode pembayaran: **Transfer**
3. Masukkan reference number: `TRF-20260614-001`
4. Proses pembayaran

**Expected Result:**
- Pembayaran berhasil dengan method = `transfer`
- Reference number `TRF-20260614-001` tersimpan dan tampil di riwayat
- Status order berubah menjadi paid

**Actual Result:** *(isi setelah testing)*  
**Status:** *(Pass / Fail)*

# Test Plan — Times420s Restaurant Management System

**Versi:** 1.0  
**Dibuat:** 2026-06-14  
**Dibuat oleh:** QA Engineer  

---

## 1. Ruang Lingkup Testing

### Aplikasi yang Ditest
| Aplikasi | Teknologi | URL |
|----------|-----------|-----|
| Owner Panel | React + TypeScript + Vite | (dev: localhost:5173) |
| Customer Menu | HTML/JS (self-order QR) | (dev: localhost:3001) |

### Fitur yang Ditest
- Authentication (login, logout, role-based access)
- Manajemen Menu (kategori & item)
- Manajemen Order (buat, edit, update status)
- Pembayaran (tunai, QRIS, transfer)
- Shift Kasir (buka & tutup shift)
- Inventory (stok bahan baku)
- Promo & Voucher
- Customer Self-Order via QR

### Di Luar Ruang Lingkup (fase ini)
- Mobile app (Flutter) — fase berikutnya
- Performance testing
- Security penetration testing

---

## 2. Jenis Testing yang Dilakukan

| Jenis | Dilakukan? | Keterangan |
|-------|-----------|------------|
| Functional Testing | ✅ | Semua fitur utama |
| Regression Testing | ✅ | Setiap ada update kode |
| Negative Testing | ✅ | Input invalid, edge case |
| Boundary Testing | ✅ | Nilai batas (harga 0, qty maks, dll) |
| UI/UX Testing | ✅ | Tampilan, responsivitas |
| API Testing | 🔄 | Fase berikutnya (Postman) |
| Automation Testing | 🔄 | Fase berikutnya (Playwright) |

---

## 3. Lingkungan Testing

| Environment | Detail |
|------------|--------|
| Browser | Chrome (latest), Firefox (latest) |
| OS | Windows / macOS |
| Database | Supabase (dev project) |
| Backend | Supabase REST API |

**⚠️ Penting:** Selalu gunakan environment **development/staging**, bukan production, saat testing.

---

## 4. Kriteria Pass/Fail

**PASS:** Actual result sesuai expected result  
**FAIL:** Actual result berbeda dari expected result, app crash, atau error tidak terduga

---

## 5. Prioritas Testing

Testing dilakukan berurutan dari module dengan risiko bisnis tertinggi:

1. 🔴 **Authentication** — kalau login rusak, seluruh app tidak bisa dipakai
2. 🔴 **Order & Payment** — fitur utama bisnis restoran
3. 🟠 **Menu Management** — operasional harian
4. 🟠 **Shift Management** — pencatatan kas
5. 🟡 **Inventory** — monitoring stok
6. 🟡 **Promo & Voucher** — fitur pendukung
7. 🟢 **Customer Menu** — pengalaman pelanggan

---

## 6. Cara Mengisi Test Case

1. Buka file TC yang relevan di folder `test-cases/`
2. Ikuti langkah-langkah di kolom **Steps**
3. Isi kolom **Actual Result** dengan apa yang benar-benar terjadi
4. Tandai **Status**: `✅ Pass` atau `❌ Fail`
5. Kalau Fail → buat bug report di folder `bug-reports/`

---

## 7. Cara Membuat Bug Report

Buat file baru di `bug-reports/` dengan format nama: `BUG-XXX-judul-singkat.md`  
Gunakan template di `qa/README.md`.

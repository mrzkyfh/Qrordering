# Regression Checklist — Mobile (Flutter)

**Jalankan setiap kali ada perubahan kode mobile sebelum rilis.**
(Checklist owner-panel ada di [REGRESSION_CHECKLIST.md](./REGRESSION_CHECKLIST.md).)

Gerbang otomatis dulu:
- [ ] `flutter analyze lib` → 0 error
- [ ] `flutter test` → semua pass (≥ 84)

---

## ✅ Auth
- [ ] Login kasir valid → `/kasir`
- [ ] Login dapur → `/kitchen`; owner/admin → `/owner`
- [ ] Password salah → toast error
- [ ] Logout → kembali ke login

## ✅ POS — Pemesanan
- [ ] Menu tampil (kasir punya `outlet_id`)
- [ ] Cari menu + filter kategori (sidebar) bekerja
- [ ] Tap ikon keranjang → item masuk cart
- [ ] Tap kartu item ber-extras → sheet extras → "Tambah ke Pesanan"
- [ ] Qty +/− dan hapus item (slide) bekerja
- [ ] Pilih Dine In + meja / Takeaway
- [ ] Subtotal & total benar
- [ ] Tidak ada overflow di layar (HP & tablet)

## ✅ POS — Draf & Pembayaran (kritikal)
- [ ] **Simpan draf** (online) berhasil → muncul di Daftar Order
- [ ] **Bayar order draft** berhasil (transisi draft→confirmed→preparing)
- [ ] Bayar order confirmed (tunai) → kembalian benar
- [ ] Metode QRIS/Debit/E-Wallet/Transfer bisa dipilih
- [ ] Klik bayar ganda tidak membuat pembayaran dobel (idempotent)
- [ ] **Lintas-hari**: buat order hari ini setelah ada order hari sebelumnya → nomor tidak duplicate

## ✅ POS — Void / Refund + PIN
- [ ] Void order aktif (alasan + PIN benar) berhasil
- [ ] Refund order paid → status cancelled
- [ ] PIN salah → ditolak
- [ ] PIN belum diatur → diarahkan ke Profil
- [ ] Atur/ubah PIN di Profil berhasil

## ✅ Daftar Order & Penjualan
- [ ] Tabel order + sidebar kategori + search bekerja
- [ ] Draf offline tampil (badge OFFLINE)
- [ ] Detail order (bottom sheet) muncul
- [ ] Penjualan: Total Penjualan & Transaksi benar; kolom Kasir & Pembayaran terisi

## ✅ Kitchen
- [ ] Antrean order realtime tampil
- [ ] Ubah status preparing → ready
- [ ] History tampil

## ✅ Shift
- [ ] Buka shift (kas awal) berhasil
- [ ] Tutup shift → expected cash = kas awal + total tunai

## ✅ Offline / Sync
- [ ] Matikan jaringan → indikator "Offline"
- [ ] Simpan draf offline → masuk antrean lokal
- [ ] Online kembali → draf tersinkron ke server

## ✅ Navigasi & UI
- [ ] Hamburger drawer (Kasir/Penjualan/Laporan/Pengaturan/Tutup Kasir) bekerja
- [ ] Tombol "Daftar Order" di top bar → buka daftar order
- [ ] Indikator status nav berubah saat pindah section
- [ ] Toast sukses/error muncul sesuai aksi
- [ ] Empty state & loading tampil wajar

## ✅ Prasyarat DB (verifikasi sekali per environment)
- [ ] Migrasi ter-apply sampai `049` (penomoran harian, security_invoker, RLS scope, PIN/refund)
- [ ] RLS: kasir hanya akses data outlet sendiri

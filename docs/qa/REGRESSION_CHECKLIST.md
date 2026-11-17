# Regression Checklist — Owner Panel
**Gunakan setiap kali ada perubahan kode sebelum deploy**

---

## ✅ Autentikasi (Wajib — semua deploy)
- [ ] Login dengan kredensial valid berhasil
- [ ] Login dengan password salah menampilkan error
- [ ] Logout menghapus session dan redirect ke /login
- [ ] Halaman terlindungi tidak bisa diakses tanpa login
- [ ] Role owner hanya bisa akses owner routes
- [ ] Role admin hanya bisa akses admin routes

---

## ✅ Owner — Branch Monitoring
- [ ] Daftar outlet tampil
- [ ] Tambah outlet baru berhasil
- [ ] Edit outlet berhasil
- [ ] Hapus outlet dengan konfirmasi
- [ ] Toggle aktif/nonaktif outlet

---

## ✅ Admin — Menu Manager
- [ ] Grid menu tampil
- [ ] Filter kategori bekerja
- [ ] Tambah menu item baru
- [ ] Upload gambar menu (< 5MB)
- [ ] Edit menu item
- [ ] Hapus menu item (konfirmasi)

---

## ✅ Admin — Stock Manager
- [ ] List bahan tampil dengan badge level stok
- [ ] Tambah bahan baru
- [ ] Adjustment stock — pembelian (qty bertambah)
- [ ] Adjustment stock — waste (qty berkurang)
- [ ] Riwayat transaksi tampil

---

## ✅ Admin — Order List
- [ ] Daftar order tampil
- [ ] Filter tanggal bekerja
- [ ] Detail order sheet muncul
- [ ] Void order dengan alasan
- [ ] Order paid tidak bisa di-void

---

## ✅ Admin — Reports
- [ ] Tab Daily Sales + chart tampil
- [ ] Tab Top Menu tampil dengan ranking
- [ ] Tab Payment Methods tampil
- [ ] Tab Finance (P&L) tampil
- [ ] Export CSV berhasil diunduh
- [ ] Export PDF berhasil diunduh

---

## ✅ Admin — Shift
- [ ] Daftar shift tampil
- [ ] Buka shift baru berhasil
- [ ] Tutup shift dengan kas akhir
- [ ] Selisih kas terhitung benar

---

## ✅ Admin — Loyalty
- [ ] Daftar member tampil
- [ ] Tambah member baru
- [ ] Adjust poin (tambah dan kurangi)
- [ ] Search member by nama/phone

---

## ✅ Admin — Expense
- [ ] Daftar pengeluaran bulan ini tampil
- [ ] Tambah pengeluaran
- [ ] Edit pengeluaran
- [ ] Hapus pengeluaran (konfirmasi)

---

## ✅ Cross-Cutting
- [ ] NoOutlet tampil saat outlet belum dipilih
- [ ] Semua form menampilkan validasi inline
- [ ] Toast sukses muncul setelah operasi berhasil
- [ ] Toast error muncul saat operasi gagal
- [ ] Loading skeleton tampil saat data dimuat
- [ ] Empty state tampil saat tidak ada data

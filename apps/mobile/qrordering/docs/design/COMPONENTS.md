# Components — QR Ordering Mobile

Katalog komponen reusable + spesifikasi visual untuk developer Flutter.
Token: [DESIGN_TOKENS.md](./DESIGN_TOKENS.md) · Aturan: [STYLE_GUIDE.md](./STYLE_GUIDE.md).

Legenda: 📁 = sudah ada di kode · 🆕 = disarankan dibuat (reusable).

---

## 1. Tombol (Buttons)

**Primary** (FilledButton) — aksi utama.
- Bg `primary`, teks putih w600, radius `10`, tinggi 48 (full-width) / 40 (toolbar).
- Loading: `CircularProgressIndicator(strokeWidth:2, color:white, 18–20px)`.
- Disabled: opacity ~0.4.
- Contoh: "Bayar", "Masuk", "Tambah ke Pesanan", "Daftar Order".

**Outline / Secondary** (OutlinedButton) — aksi sekunder.
- Border `primary` atau `border`, teks senada. Mis. "Coba lagi".

**Danger** — aksi destruktif.
- `FilledButton`/`OutlinedButton` warna `error`. Mis. "Void", "Refund", "Keluar". **Wajib konfirmasi.**

**Icon Button** — target ≥44px, `tooltip` wajib. Mis. ☰ menu, refresh, toggle mata.

**Quick-add (cart icon)** 📁 [`menu_item_card.dart`] — lingkaran putih + ikon keranjang `primary`, pojok kanan-atas kartu menu; nonaktif bila item habis.

## 2. Input Fields 📁

- Field bordered: `fillColor` putih, border `border` (`radius 10`), fokus border `primary` 1.6px.
- Label **di atas** field (w600, 13px), gap 6.
- Placeholder `textDisabled`.
- Password: `suffixIcon` toggle mata (outlined).
- Search: `prefixIcon` search 20px, `isDense`, fill `surfaceVariant`.
- Validasi: pesan error merah di bawah field.
- Referensi: `login_page.dart` (`_dec()`), `_SearchField` di order list.

## 3. Cards 📁/🆕

**Base Card** — `surface`, border `border`, radius `12`, elevation 0 (+ shadow halus opsional).

**Stat Card** 📁 [`penjualan_page.dart`] — label `caption` `textSecondary` + nilai `display`/`h2` bold. Untuk Total Penjualan/Transaksi.

**Menu Item Card** 📁 [`menu_item_card.dart`]
- Anatomi: thumbnail (atas, flex 3) + info (bawah, flex 2: nama 2 baris → deskripsi fleksibel/clip → harga `primary` bold).
- Overlay quick-add (kanan-atas), overlay "Habis" bila tidak tersedia.
- Placeholder gambar: tint `accent` + ikon `restaurant_menu` `primary`.
- **Anti-overflow**: deskripsi `Expanded`/clip (jangan biarkan kolom melebihi tinggi kartu).

## 4. Status Badge 📁

- Pill: teks+`label` warna status, bg `status.withValues(alpha:0.15)`, radius `full`, padding 8×2.
- Mapping label: confirmed→"Dikonfirmasi", preparing→"Dimasak", ready→"Siap", served→"Disajikan", paid→"Lunas", cancelled→"Dibatalkan", void→"Void". (lihat `_StatusBadge`)

## 5. Cart Panel 📁 [`cart_panel.dart`]

- Header "Current Order" + toggle Dine In/Takeaway + "Pilih meja".
- List item: thumbnail kecil, nama, qty stepper (− n +), harga.
- Empty state: ikon keranjang dalam lingkaran `accent` + "Belum ada item".
- Summary: subtotal, diskon, pajak, total (bold), tombol bayar.
- Input loyalty/promo: field + tombol kecil **berlebar tetap** (hindari unbounded width di `Row`).

## 6. Navigation

**Hamburger Drawer** 📁 [`kasir_shell.dart`]
- Header: avatar gradient (52px, radius 16) + nama bold + role sebagai pill `accent`/`accentForeground`.
- Item: ikon dalam kotak `radius-sm` + label. **Aktif** = bg `accent`, ikon/teks `primary`, w700, highlight pill (margin 12, radius 12).
- Item bahaya ("Tutup Kasir") = warna `error`, dipisah divider.
- Bg `surface`, sudut kanan membulat 20, elevation 2.

**Top Bar (POS)** 📁 [`pos_page.dart`] — ☰ kiri + logo + Spacer + tombol "Daftar Order" kanan.

**Category Sidebar (vertikal)** 📁 — judul "Kategori Produk" + tile; aktif = bg `accent` + border `primary` + teks `primary` w600. Lebar 150.

## 7. Tabel (POS landscape) 📁 [`order_list_page.dart`, `penjualan_page.dart`]

- Header row: `caption` w600 `textSecondary`, kolom pakai `flex` konsisten dgn baris.
- Baris: `InkWell` → detail; teks `body-sm`; kolom angka rata kanan bold `primary`.
- Pemisah `Divider` `border`. Empty state terpusat.
- Sidebar kategori/filter di kiri (220px) + tabel `Expanded`.

## 8. Dialog & Bottom Sheet 📁

- **Dialog** (AlertDialog): judul `h3`, body `body`, aksi kanan-bawah (batal teks + aksi primary/danger).
- **PIN Dialog** 📁 — field obscure, angka, terpusat, `letterSpacing` 8; verifikasi via RPC.
- **Bottom Sheet** (detail order, extras, payment): handle bar, sudut atas `16–20`, `DraggableScrollableSheet` untuk konten panjang.

## 9. Feedback

**Toast** 🆕→📁 [`core/widgets/app_toast.dart`] — `AppToast.error/success(...)`. Gunakan untuk notifikasi singkat (gantikan SnackBar polos). Warna sesuai semantik (error merah, sukses `secondary`).

**Loading** — `CircularProgressIndicator` terpusat untuk halaman; spinner kecil inline untuk tombol.

**Empty State** 🆕 — pola seragam: ikon outline 64px `textDisabled` + judul `textSecondary` (+ aksi opsional). Saran: ekstrak jadi `EmptyState` widget reusable (sekarang masih diulang per halaman).

## 10. Section Active Indicator 📁

Bar vertikal `primary` (lebar 3, tinggi ~26) di tepi item nav aktif + AnimatedContainer 220–240ms.

---

## Rekomendasi reusable berikutnya (kurangi duplikasi)
- `AppButton` (varian primary/outline/danger + loading) — saat ini gaya tombol diulang manual.
- `EmptyState`, `SectionCard`, `DataTableHeader/Row`, `StatusBadge` (sudah ada, jadikan shared), `LabeledField`.
- `AppSpacing` / `AppRadius` constants untuk hapus magic-number.

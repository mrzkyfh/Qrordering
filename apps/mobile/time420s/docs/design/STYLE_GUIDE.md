# Style Guide — Time 420s Mobile

Panduan penerapan visual. Baca bersama [DESIGN_TOKENS.md](./DESIGN_TOKENS.md) & [COMPONENTS.md](./COMPONENTS.md).
Mood: **Modern & Efisien (POS)** — bersih, kontras jelas, cepat dipakai, ramah jari.

---

## 1. Prinsip Desain

1. **Cepat & jelas** — alur kasir tak boleh ragu. Aksi utama selalu menonjol (orange), aksi bahaya merah.
2. **Hierarki kuat** — angka/harga & status paling menonjol; metadata sekunder redup (`textSecondary`).
3. **Konsisten dengan brand** — orange `#FF6600` hanya untuk aksi/aktif/harga, bukan dekorasi.
4. **Ramah jari** — target sentuh ≥ 44px, jarak antar tombol cukup.
5. **Tenang** — banyak putih, border tipis `#E3E3E3`, shadow halus; hindari ramai.

## 2. Warna — Aturan Pakai

**Orange (`primary`)** — hanya untuk: tombol aksi utama, item/section aktif, harga, ikon brand. Jangan untuk teks panjang atau background luas (kecuali splash/login logo).

**Netral** — `background` untuk scaffold, `surface` (putih) untuk kartu/panel, `border` untuk garis & outline.

**Teks** — `textPrimary` utama, `textSecondary` pendukung, `textDisabled` placeholder. Rasio kontras minimal **4.5:1** (teks normal).

**Status** — pakai warna status sesuai tabel token; jangan campur arti (mis. hijau `secondary` hanya untuk sukses, bukan tombol biasa).

**Bahaya** — `error` untuk Void/Refund/Hapus/Logout. Selalu beri konfirmasi sebelum aksi destruktif.

### Do / Don't
- ✅ Tombol bayar = `primary` solid, teks putih.
- ✅ Item aktif = background `accent` + teks/ikon `primary`.
- ❌ Jangan pakai orange untuk teks paragraf.
- ❌ Jangan pakai >1 warna aksi dalam satu layar tanpa makna.

## 3. Tipografi

- Satu typeface (Roboto default). Bedakan hierarki lewat **size + weight**, bukan banyak warna.
- Judul: bold. Sub-judul: w600. Body: regular. Label kecil: w600 + uppercase + `letterSpacing` 0.5.
- Angka/harga: **bold + `primary`**.
- Maks 2 baris untuk nama menu (ellipsis), 1 baris untuk metadata baris tabel.

## 4. Spacing & Layout

- Pakai skala kelipatan 4 (lihat token). Hindari nilai acak.
- Padding konten halaman: `16`. Padding kartu: `12–20`.
- Form terpusat dibatasi `maxWidth 380` agar rapi di tablet & HP.
- Layout POS landscape: `[sidebar kategori 150] | [grid menu fleksibel] | [cart 300]`.
- Gunakan `Expanded`/`Flexible` agar tidak overflow di lebar berbeda; jangan kunci lebar absolut untuk konten dinamis.

## 5. Ikon

- Set: Material Icons (outline untuk default, filled untuk state aktif).
- Ukuran: 18 (inline), 20–22 (tombol/nav), 24 (header).
- Ikon aksi penting selalu didampingi label teks (mis. "Daftar Order", "Bayar").
- Bungkus ikon nav/menu dalam kotak `radius-sm` dengan tint saat aktif.

## 6. Bentuk & Permukaan

- Sudut membulat konsisten: field/tombol `10`, kartu `12`, kartu besar/dialog `16`, sheet `20`.
- Kartu utama pakai **border tipis** (`border`) + shadow halus, **elevation 0** (flat modern), bukan shadow tebal.
- Bottom sheet: sudut atas membulat `16–20`, handle bar abu di tengah.

## 7. Motion

- Halus & singkat (150–280ms, `easeOut`). Animasi memberi umpan balik, bukan pamer.
- Perpindahan state (aktif/nonaktif) di-animate (warna, scale ringan ≤1.1x).
- Hindari animasi yang menahan aksi kasir (jangan blokir input saat transisi).
- Hindari `AnimatedSwitcher` membungkus layout `Row`+`Expanded` penuh (pernah memicu error layout) — animasikan elemen kecil saja.

## 8. State Komponen (wajib)

Setiap komponen interaktif punya: **default, hover/pressed, selected/active, disabled, loading, error/empty**.
- Loading tombol: spinner putih 18–20px, teks "Memproses…".
- Disabled: opacity turun / `textDisabled`, non-aktif.
- Empty state: ikon outline 64px `textDisabled` + pesan `textSecondary`.

## 9. Konten & Bahasa

- Bahasa Indonesia, ringkas, kapitalisasi kalimat ("Tambah ke Pesanan", bukan "TAMBAH KE PESANAN").
- Mata uang via `CurrencyFormatter` (format Rupiah konsisten).
- Tanggal: `d MMM yyyy, HH:mm` (mis. `2 Jun 2026, 13:19`).
- Pesan error spesifik & solutif (mis. "Akun belum terhubung ke outlet").

## 10. Aksesibilitas

- Kontras teks ≥ 4.5:1; jangan andalkan warna saja untuk makna (sertakan ikon/teks status).
- Target sentuh ≥ 44px.
- `tooltip` pada IconButton tanpa label.
- Dukung teks placeholder yang jelas; toggle password (mata) tersedia.

## 11. Konsistensi lintas-app

Mobile mengikuti brand owner panel & customer menu (orange `#FF6600`, radius & netral senada). Saat menambah layar baru, ambil token dari `AppColors`/theme — jangan bikin warna/spacing baru tanpa alasan.

# UI Review — Time 420s Mobile (Analisis Kritis)

Tanggal: 2026-06-02 · Reviewer: UI Designer · Konteks: user merasa UI mobile "masih kurang bagus".
Acuan: [DESIGN_SYSTEM.md](./DESIGN_SYSTEM.md), kode di `lib/features/pos`, `lib/core/theme`.

Penilaian umum: **fungsional & konsisten warna brand, tapi terasa _flat_ dan "setengah jadi"** — kurang kedalaman (depth), hierarki tipografi lemah, ada elemen mati, dan boros ruang. Di bawah: temuan + perbaikan, diurut dampak.

---

## 🔴 Prioritas Tinggi (paling terasa)

### 1. Semua panel putih → datar & menyatu (kurang "depth")
**Masalah:** Di POS, top bar (putih) + header (putih) + sidebar kategori (putih) + cart (putih) hanya dipisah border tipis `#E3E3E3`. Tidak ada kontras zona → layar terasa rata, murah, "belum jadi".
**Lokasi:** `pos_page.dart`, `cart_panel.dart`.
**Perbaikan:**
- Jadikan `background #F7F7F7` sebagai **kanvas**, dan panel = **kartu putih mengambang** (gap 8–12, radius 14–16, shadow halus), bukan blok putih penuh-lebar berdempetan.
- Beri sedikit pemisah warna antar zona (mis. sidebar kategori `surface`, area grid `background`).
- Hasil: ada kedalaman, mata mudah memetakan area.

### 2. Dua header bertumpuk → boros ruang vertikal
**Masalah:** Ada `_PosTopBar` (☰ + logo kecil + "Daftar Order") **dan** header `_MenuPanel` ("Selamat datang, kasir" + search + filter). Dua baris header memakan ruang mahal di POS; sapaan "Selamat datang" kurang relevan untuk kasir kerja cepat.
**Lokasi:** `pos_page.dart` (`_PosTopBar` + header `_MenuPanel`).
**Perbaikan:** Gabung jadi **satu baris**: `☰ · [nama outlet/logo] · [search lebar] · [Daftar Order]`. Buang greeting (atau jadikan teks kecil 1 baris). Hemat ~64px tinggi.

### 3. Elemen mati (ikon filter tanpa aksi)
**Masalah:** Ikon `tune_outlined` di samping search **tidak punya onTap** — terlihat bisa diklik tapi mati. Membingungkan & menurunkan kepercayaan.
**Lokasi:** `pos_page.dart` header (Container ikon filter).
**Perbaikan:** Hapus, **atau** fungsikan (mis. sheet filter kategori/ketersediaan).

### 4. Tipografi terasa "murah"
**Masalah:** Font default Roboto + ukuran kecil seragam (11–13px di hampir semua tempat) → hierarki lemah, kesan generik. Angka/harga kurang menonjol untuk konteks kasir.
**Perbaikan:**
- Pakai **Inter** via `google_fonts` (selaras owner-panel & customer-menu) → langsung naik kelas.
- Perkuat skala: judul 18–20 bold, harga 15–16 bold `primary`, body 14, caption 12. Naikkan sedikit line-height.

---

## 🟠 Prioritas Menengah

### 5. Konsistensi token belum tuntas
**Masalah:** 8 file masih hardcode `0xFFE2E8F0` (biru-abu) sementara token `AppColors.border = #E3E3E3` (netral). Dua nuansa garis berbeda → inkonsistensi halus tapi terasa.
**Lokasi:** `pos_page.dart`, `cart_panel.dart`, `payment_page.dart`, `order_list_page.dart`, `kitchen_queue_page.dart`, `owner_monitor_page.dart`, `customer_menu_page.dart`, `pin_field_theme.dart`.
**Perbaikan:** Ganti semua ke `AppColors.border`.

### 6. Kartu menu kurang "hidup"
**Masalah:** Placeholder = satu ikon di tint accent; bila banyak item tanpa foto, grid jadi seragam & kosong. Harga relatif kecil.
**Catatan baik:** press-animation (scale 0.97 + shadow) **sudah ada** — bagus.
**Perbaikan:** Placeholder lebih kaya (inisial + warna per-kategori, atau pola lembut), harga lebih besar/menonjol, badge kategori kecil opsional, tampilkan badge qty bila item sudah di-cart.

### 7. Cart panel — hierarki "Total" & input sesak
**Masalah:** Tombol loyalty/promo mungil (lebar 60–64) terasa sempit & bertumpuk; baris **Total** kurang dominan dibanding pentingnya.
**Perbaikan:** Total = angka besar bold (18–20) di blok terpisah dengan sedikit aksen; rapikan input loyalty/promo (collapsible "Tambah member/voucher" agar tak selalu memakan ruang).

### 8. Density & target sentuh
**Masalah:** Banyak teks 11–13 & beberapa target kecil; POS sering dipakai cepat/berdiri.
**Perbaikan:** Naikkan teks utama ke 14–15, pastikan semua tombol ≥ 44–48px, beri ruang antar baris.

---

## 🟡 Prioritas Rendah / Penyempurnaan

### 9. Aksen orange kurang dimanfaatkan
Layar didominasi putih/abu → terasa hambar. Tambah sentuhan accent terukur (garis tipis di header kartu aktif, ikon, highlight total) tanpa berlebihan.

### 10. Loading & empty state
Loading = spinner polos. Tambah **skeleton** sederhana (kartu abu beranimasi) untuk kesan lebih halus. Empty state seragamkan jadi 1 komponen `EmptyState`.

### 11. Responsif (HP portrait)
Layout 3 kolom (`sidebar 150 | grid | cart 300`) mengasumsikan **tablet landscape**. Di HP portrait akan sesak/pecah. Tentukan: target tablet saja, atau adaptif (cart → bottom sheet, sidebar kategori → chip horizontal di layar sempit).

---

## Ringkasan "Quick Win" (dampak besar, usaha kecil)
1. Gabung dua header jadi satu + hapus ikon filter mati. *(#2, #3)*
2. Ganti font ke **Inter** + perkuat skala tipografi. *(#4)*
3. Beri "depth": panel jadi kartu mengambang di kanvas `background`. *(#1)*
4. Bersihkan `0xFFE2E8F0` → `AppColors.border`. *(#5)*
5. Perbesar harga & perkuat blok Total. *(#6, #7)*

## Paket "Polish Lanjutan"
- Skeleton loading + `EmptyState` reusable. *(#10)*
- Placeholder kartu menu yang lebih kaya + badge qty. *(#6)*
- Strategi responsif HP portrait. *(#11)*
- Ekstrak `AppButton`, `AppSpacing/AppRadius` (lihat COMPONENTS backlog).

> Catatan: pondasi (brand orange, token, drawer modern, login) sudah baik. Masalah utama bukan warna, tapi **depth, hierarki tipografi, dan kerapian ruang**. Lima quick-win di atas akan paling terasa.

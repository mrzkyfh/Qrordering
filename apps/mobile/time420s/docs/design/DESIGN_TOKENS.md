# Design Tokens — Time 420s Mobile

Sumber kebenaran token visual. Mood: **Modern & Efisien (POS)**. Platform: **Flutter (mobile/tablet)**.
Implementasi saat ini: [`lib/core/theme/app_colors.dart`](../../lib/core/theme/app_colors.dart) & [`lib/core/theme/app_theme.dart`](../../lib/core/theme/app_theme.dart).

> Dark theme: token sudah didefinisikan di bawah, namun **belum** diimplementasikan di `app_theme.dart` (app masih light-only). Lihat catatan implementasi di akhir.

---

## 1. Color — Brand

| Token | Light | Dark (usulan) | Pemakaian |
|-------|-------|---------------|-----------|
| `primary` | `#DC2626` | `#EF4444` | Aksi utama (**1 CTA/layar**), nav aktif, Total akhir, badge notif — **BUKAN harga item** |
| `primaryDark` | `#B91C1C` | `#DC2626` | Gradient/pressed |
| `primarySubtle` | `#FEF2F2` | `#2A1212` | Tint merah sangat tipis (highlight kecil) |
| `accent` | `#F1F5F9` | `#23272E` | Background tint item aktif / chip (slate-100, **netral**) |
| `accentForeground` | `#DC2626` | `#EF4444` | Teks/ikon aktif di atas `accent` |
| `secondary` | `#475569` | `#94A3B8` | Netral sekunder (slate-600) — menggantikan teal lama |

## 2. Color — Netral & Permukaan

| Token | Light | Dark (usulan) | Pemakaian |
|-------|-------|---------------|-----------|
| `canvas` | `#F8FAFC` | `#0F1115` | **Latar scaffold + AppBar** (slate-50) — kartu putih "mengambang" di atasnya |
| `background` | `#F8FAFC` | `#181B20` | Latar grid/area di balik kartu |
| `surface` | `#FFFFFF` | `#181B20` | Kartu, panel, dialog |
| `surfaceVariant` | `#F1F5F9` | `#23272E` | Field, kotak ikon (slate-100) |
| `border` | `#E5E7EB` | `#2C313A` | Garis pemisah, outline kartu/field |
| `borderStrong` | `#CBD5E1` | `#3A414B` | Divider tegas (slate-300) |
| `textPrimary` | `#111827` | `#F2F4F7` | Teks utama & **harga item** |
| `textSecondary` | `#64748B` | `#9AA3AF` | Teks sekunder/caption (slate-500) |
| `textDisabled` | `#94A3B8` | `#4B5563` | Placeholder, ikon nonaktif (slate-400) |

## 3. Color — Semantik & Status

| Token | Hex | Pemakaian |
|-------|-----|-----------|
| `error` | `#EF4444` | Error, void, hapus, tombol bahaya |
| `warning` | `#F59E0B` | Peringatan, status "dimasak" |
| `info` | `#3B82F6` | Info, status "dikonfirmasi" |
| `statusDraft` | `#94A3B8` | Order draft |
| `statusConfirmed` | `#3B82F6` | Dikonfirmasi |
| `statusPreparing` | `#F59E0B` | Dimasak |
| `statusReady` | `#10B981` | Siap |
| `statusServed` | `#6366F1` | Disajikan |
| `statusPaid` | `#22C55E` | Lunas |
| `statusCancelled` | `#EF4444` | Dibatalkan / refund |
| `statusVoid` | `#6B7280` | Void |
| `tableAvailable / Occupied / Reserved / Dirty` | `#10B981 / #EF4444 / #F59E0B / #94A3B8` | Status meja |

> Pola badge status: teks & ikon pakai warna status; background = `warna.withValues(alpha: 0.12–0.15)`.

## 4. Spacing (kelipatan 4)

| Token | px | Pemakaian |
|-------|----|-----------|
| `space-2` | 2 | Jarak mikro antar teks |
| `space-4` (`xs`) | 4 | Padding rapat |
| `space-6` | 6 | Gap label–field |
| `space-8` (`sm`) | 8 | Gap antar item kecil |
| `space-12` (`md`) | 12 | Padding kartu, gap default |
| `space-16` (`lg`) | 16 | Padding konten, grid gap |
| `space-20` (`xl`) | 20 | Padding section/card besar |
| `space-24` (`2xl`) | 24 | Margin halaman |
| `space-32` (`3xl`) | 32 | Pemisah blok besar |

## 5. Radius

| Token | px | Pemakaian |
|-------|----|-----------|
| `radius-sm` | 8 | Tombol kecil, kotak ikon, chip |
| `radius-md` | 10 | Tombol, input field |
| `radius-lg` | 12 | Kartu, item nav/drawer, badge highlight |
| `radius-xl` | 16 | Kartu besar, dialog, kartu login |
| `radius-2xl` | 20 | Bottom sheet (atas), avatar drawer |
| `radius-full` | 999 | Pill, avatar lingkaran, FAB |

## 6. Elevation / Shadow

| Token | Nilai | Pemakaian |
|-------|-------|-----------|
| `shadow-card` | `color: black 4%`, blur 16, y 6 | Kartu (login, stat) |
| `shadow-sm` | `color: black 6%`, blur 12, y 4 | Kartu menu |
| `shadow-brand` | `color: primary 30%`, blur 18, y 8 | Logo/elemen brand |
| `elevation-drawer` | Material elevation 2 | Drawer |
| `elevation-0` | 0 | App bar, kartu (pakai border, bukan shadow) |

## 7. Typography (**Plus Jakarta Sans** via `google_fonts` → `AppText`)

> Implementasi: `lib/core/theme/app_typography.dart`. Pakai `AppText.displayLg/displaySm/h1/h2/h3/bodyLg/body/caption/label/price` alih-alih `TextStyle(fontSize: ...)` manual. Target 9 gaya semantik (bukan 22 ukuran liar). **`AppText.price` berwarna `textPrimary` (hitam)**, bukan merah.


| Token | Size | Weight | Pemakaian |
|-------|------|--------|-----------|
| `display` | 24 | Bold (700) | Judul utama (login, total besar) |
| `h2` | 18 | Bold | Judul section / header halaman |
| `h3` | 17 | Bold | Judul kartu/sheet |
| `title` | 16 | w600 | Sub-judul, total |
| `body` | 14 | Regular | Teks utama |
| `body-sm` | 13 | Regular | Teks sekunder, baris tabel |
| `caption` | 12 | Regular | Keterangan, header tabel |
| `label` | 11 | w600/w700 | Label kecil, badge, overline (uppercase) |
| `numeric/price` | 13–22 | Bold | Harga & angka (warna `primary`) |

> Font kustom **Plus Jakarta Sans** sudah aktif via `google_fonts` (lihat `AppTheme._textTheme` & `AppText`).

## 8. Motion

| Token | Durasi | Curve | Pemakaian |
|-------|--------|-------|-----------|
| `motion-micro` | 150ms | `easeOut` | Hover/press, perubahan kecil |
| `motion-standard` | 220ms | `easeOut` | Highlight nav, scale ikon, AnimatedContainer |
| `motion-emphasis` | 280ms | `easeOutCubic` | Transisi list/section |
| Library | — | — | `flutter_animate` (^4.5.2) tersedia untuk animasi deklaratif |

## 9. Sizing & Target Sentuh

| Token | Nilai |
|-------|-------|
| `touch-min` | 44–48 px (wajib untuk semua tombol/ikon yang bisa diklik) |
| `icon-sm / md / lg` | 18 / 20–22 / 24 px |
| `avatar-sm / md` | 36 / 52 px |
| `cart-panel-width` | 300 px (POS landscape) |
| `category-sidebar-width` | 150 px |
| `menu-grid-tile` | `MaxCrossAxisExtent 200`, ratio 0.72 |
| `content-max-width` | 380 px (form terpusat spt login) |

---

## Catatan implementasi (Flutter)

- Token warna: tambah konstanta di `AppColors`. Untuk dark theme, buat `AppTheme.dark` dengan `ColorScheme.dark(...)` + override seperti `AppTheme.light`, lalu set `MaterialApp.themeMode`.
- Hindari hex hardcode di widget (masih ada sisa `Color(0xFFE2E8F0)` di beberapa file) → ganti ke `AppColors.border`.
- Token spacing/radius bisa dibungkus jadi `class AppSpacing`/`AppRadius` agar tidak magic-number.

# Design System — QR Ordering Mobile

Dokumen payung design system aplikasi **mobile (Flutter)** QR Ordering (POS resto).
Mood: **Modern & Efisien (POS premium — vibe Stripe/Linear/Square)** · Brand: merah `#DC2626` (dipakai sebagai AKSEN ~10%, mayoritas UI netral slate) · Font: **Plus Jakarta Sans** · Theme: Light (aktif) + Dark (token disiapkan).

> **Aturan warna inti:** 70% netral (slate) · 20% surface/border · 10% merah brand. Merah HANYA untuk **1 CTA utama per layar, item nav aktif, Total akhir transaksi, badge notifikasi, dan status kritis (void)**. **Harga item = `textPrimary` (hitam)**, bukan merah. Shadow selalu netral (hitam transparan), tidak pernah berwarna brand.

## Daftar Dokumen
| Dokumen | Isi |
|---------|-----|
| [DESIGN_TOKENS.md](./DESIGN_TOKENS.md) | Nilai mentah: warna (light+dark), spacing, radius, tipografi, elevation, motion, sizing |
| [STYLE_GUIDE.md](./STYLE_GUIDE.md) | Prinsip & aturan pakai: warna, tipografi, layout, ikon, motion, aksesibilitas |
| [COMPONENTS.md](./COMPONENTS.md) | Katalog komponen + spesifikasi & state |
| DESIGN_SYSTEM.md | (ini) Overview, prinsip, fondasi, theming, cara pakai |

---

## 1. Prinsip Inti
1. **Speed-first** — UI melayani kecepatan kasir; aksi utama selalu jelas & besar.
2. **Hierarki** — harga, status, dan aksi paling menonjol; metadata redup.
3. **Konsisten** — satu sumber token (`AppColors`/`AppTheme`); tak ada warna/spacing liar.
4. **Ramah jari** — target ≥44px, jarak cukup, layout responsif (HP & tablet).
5. **Tenang & modern** — flat, border tipis, shadow halus, banyak putih.

## 2. Fondasi (Foundations)
- **Warna**: brand (merah `#DC2626`), netral/permukaan (slate), semantik & status. → token §1–3.
- **Tipografi**: Plus Jakarta Sans, skala 11–30, hierarki via size+weight. → token §7 & `AppText`.
- **Spacing**: skala kelipatan 4 (`AppSpacing`). → token §4.
- **Bentuk**: radius 8/12/16/20/full (`AppRadius`). → token §5.
- **Elevation**: flat (border) + shadow halus. → token §6.
- **Motion**: 150–280ms `easeOut`, `flutter_animate`. → token §8.

## 3. Theming (Light & Dark)

**Light (aktif)** — `canvas/background #F8FAFC` (slate-50), `surface #FFFFFF`, teks gelap. Implementasi: `AppTheme.light`.

**Dark (token siap, belum diimplementasi)** — palette di [DESIGN_TOKENS.md §1–2](./DESIGN_TOKENS.md). Rencana implementasi:
```dart
// app_theme.dart
static ThemeData get dark => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: AppColors.primary, brightness: Brightness.dark,
  ).copyWith(
    primary: AppColorsDark.primary,        // #FF7A1A
    surface: AppColorsDark.surface,        // #181B20
    outline: AppColorsDark.border,         // #2C313A
    // ...
  ),
  scaffoldBackgroundColor: AppColorsDark.background, // #0F1115
  // mirror struktur AppTheme.light
);
// MaterialApp(themeMode: ThemeMode.system, theme: light, darkTheme: dark)
```
> Saat menambah dark: pisahkan token ke `AppColorsLight`/`AppColorsDark` atau pakai `Theme.of(context).colorScheme` di widget (hindari konstanta warna langsung agar otomatis ikut theme).

## 4. Arsitektur Tema di Kode
```
lib/core/theme/
  app_colors.dart      → konstanta warna (token warna)
  app_spacing.dart     → AppSpacing (kelipatan 4)
  app_radius.dart      → AppRadius (sm/md/lg/xl/full + BorderRadius siap pakai)
  app_shadow.dart      → AppShadow (card/sm/modal — selalu netral)
  app_typography.dart  → AppText (skala semantik Plus Jakarta Sans)
  app_theme.dart       → ThemeData (colorScheme, button/input/card theme)
lib/core/widgets/
  app_toast.dart       → feedback toast
  pin_field_theme.dart
```
> Gunakan `AppText.*`, `AppSpacing.*`, `AppRadius.*`, `AppShadow.*` alih-alih magic number. Hindari `TextStyle(fontSize: ...)` manual & hex hardcode.
- Widget **ambil warna dari token/`colorScheme`**, bukan hex hardcode.
- Tema komponen (FilledButton, Input, Card, BottomNav) dipusatkan di `app_theme.dart`.

## 5. Pola Penggunaan (Patterns)
- **Halaman daftar (tabel)**: sidebar filter kiri + tabel `Expanded` + search + empty state.
- **Halaman form**: terpusat `maxWidth 380`, label di atas field, tombol full-width.
- **POS**: top bar (☰ + Daftar Order) → `[kategori 150 | grid | cart 300]`.
- **Aksi sensitif** (void/refund/tutup kasir): warna `error` + konfirmasi (+ PIN bila relevan).
- **Navigasi**: hamburger drawer (Kasir/Penjualan/Laporan/Pengaturan/Tutup Kasir) + indikator aktif.

## 6. Aksesibilitas (ringkas)
Kontras ≥4.5:1 · target ≥44px · makna tak hanya warna (sertakan ikon/teks) · tooltip pada IconButton.

## 7. Tata Kelola
- Tambah token baru hanya bila benar-benar perlu; utamakan reuse.
- Setiap komponen baru: definisikan semua state (default/active/disabled/loading/empty/error).
- Konsistensi lintas-app dijaga dengan brand owner panel.
- **Backlog konsistensi** (lihat COMPONENTS §akhir): ekstrak `AppButton`, `EmptyState`, `AppSpacing/AppRadius`; ganti sisa hex hardcode (`0xFFE2E8F0`) ke `AppColors.border`.

## 7b. Prinsip layout "Floating Card" (referensi bitepoint)
- **Kanvas lembut**: scaffold + AppBar pakai `canvas` (#F8FAFC / slate-50), bukan putih. Kartu putih (`surface`) "mengambang" di atasnya → kedalaman tanpa garis berat.
- **Kartu**: radius `16`, border tipis (`border` @60% alpha), padding 16.
- **Tombol/field**: radius `12`. Primary solid, secondary outline.
- **Badge status**: pill (radius 20), teks+ikon warna status, bg `warna @12–15%`.
- **Avatar pesanan**: inisial (TA/QR/M{meja}) di lingkaran bg `warna status @18%`.
- Brand (merah/teal) dipertahankan; hanya layout/struktur yang meniru bitepoint.

## 8. Changelog
- 2026-06-09 — **Phase 3 lanjutan**: CTA "Bayar" dibuat dominan (full-width + nominal total, "Simpan" jadi ikon sekunder); empty-state diseragamkan (`AppEmptyState`/`ReportEmpty`); touch target chevron period-bar dikembalikan ≥48px; **normalisasi ukuran font pecahan** (13.5/12.5/11.5/10.5/9.5 → integer) di seluruh `lib`; **order detail → bottom sheet asli** (payment tetap dialog karena form fokus).
- 2026-06-09 — **Redesign Phase 2–3**: ekstrak komponen bersama (`AppErrorView`, `AppSearchField`, `OutletPicker`) + dedup duplikat di dashboard/reports. **Sapu tint pink**: semua fill `primary @5–15%` (badge peran/durasi, avatar, kartu shift, ikon order, kategori/nav aktif, tile metode bayar, chip qty/rank) → netral slate; state aktif kini = fill slate + indikator merah (pola Linear/Stripe). Shadow brand merah → netral. Laporan ringkasan → kartu metrik `StatCard`. Touch target qty/quick-add dinaikkan (a11y). Tombol "Bayar" → pill bersih. Pengecualian: badge "Wajib" tetap merah (semantik field wajib).
- 2026-06-08 — **Redesign Phase 1**: dokumen disinkronkan ke realita kode (brand merah `#DC2626`, font Plus Jakarta Sans, canvas `#F8FAFC`). Ditambah token `AppSpacing`/`AppRadius`/`AppShadow`/`AppText`. Disiplin warna: harga → `textPrimary` (hitam), shadow brand merah dihapus (jadi netral), hex hardcode → token.
- 2026-06-08 — Adopsi layout "floating card" bitepoint: token `canvas`, scaffold/AppBar canvas, kartu radius 16, tombol/field radius 12 (brand tetap).
- 2026-06-02 — Inisialisasi design system mobile (brand orange #FF6600, mood POS modern-efisien, light+dark tokens).

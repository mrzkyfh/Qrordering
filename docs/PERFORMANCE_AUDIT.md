# Performance Audit — Time 420s POS (Mobile)
**Tanggal:** 2026-07-05
**Metode:** Terukur (APK breakdown, build split) + static analysis hot-path
**Stack:** Flutter + BLoC + Supabase

---

## Ringkasan

Dua temuan berdampak nyata: **ukuran APK** (terukur) dan **re-sort daftar order tiap keystroke** (static). Sisanya sudah baik (grid/list pakai lazy `.builder`, tinggi sel POS fixed).

---

## 🔴 PERF-1 — APK Gemuk (85MB): 3 ABI Digabung Jadi Satu
**Terukur:**
| Build | Ukuran | Delta |
|-------|--------|-------|
| Fat APK (default, 3 ABI) | **85 MB** | — |
| `--split-per-abi` arm64-v8a | **35 MB** | **−59%** |
| `--split-per-abi` armeabi-v7a | 31 MB | −64% |

**Sebab:** APK universal membawa `libflutter.so` + `libapp.so` + `libbarhopper_v3.so` (ML Kit QR) untuk **ketiga** arsitektur (arm64, armv7, x86_64) sekaligus. Tiap HP hanya butuh satu.

**Rekomendasi:**
- **Play Store:** `flutter build appbundle` (AAB) → Google auto-split per device. **Wajib untuk rilis Play Store.**
- **Distribusi APK langsung (sideload ke tablet kasir):** `flutter build apk --release --split-per-abi` → bagikan `app-arm64-v8a-release.apk` (mayoritas tablet modern). Hemat ~50MB per install.
- `x86_64` hampir tak perlu untuk device produksi (hanya emulator) — bisa di-exclude.

**Dampak:** waktu download & storage device turun ~59%. Tidak mengubah performa runtime, tapi penting untuk deployment multi-device.

---

## 🟡 PERF-2 — Daftar Order Re-Sort Penuh Tiap Rebuild / Keystroke
**File:** `lib/features/orders/presentation/pages/order_list_page.dart:119-140` (`_allSorted`), dipanggil di `build()` baris **195** & **853**.

**Masalah:**
```dart
final all = _allSorted(state);   // di dalam build()
// _allSorted: gabung offlineDrafts + active + completed → .where().toList() → .sort()
```
- `build()` jalan setiap **setState** — termasuk `onChanged: (v) => setState(() => _query = v)` di search (baris 235). Artinya **setiap ketikan huruf → seluruh daftar order di-sort ulang** (O(n log n)).
- Tiap tab chip menghitung `all.where(t.match).length` → **4 pass filter tambahan** per rebuild (baris ~221).
- Pada outlet ramai (ratusan order/hari), mengetik di pencarian = ratusan item di-sort per karakter → jank/lag di tablet kelas menengah.

**Rekomendasi:**
- **Memoize** hasil sort: simpan `List<Order> _sortedCache` + `_cacheKey` (mis. jumlah + updatedAt terbaru order). Re-sort hanya bila data order berubah, BUKAN saat query/tab berubah.
- Filter query & tab dikerjakan di atas list yang sudah ter-sort (murah, O(n) tanpa sort).
- Idealnya sorting dipindah ke `OrdersBloc` (state simpan list sudah terurut) → `build()` tinggal filter.

**Estimasi:** ~S. Refactor lokal di 1 file.

---

## 🟢 Positif (sudah baik)
- POS menu grid & order grid pakai `GridView.builder` / `ListView.builder` → **lazy render**, tidak materialisasi semua item.
- POS card pakai `mainAxisExtent: 205` (tinggi sel fixed) → tak ada recompute layout per item.
- `ListView(` non-builder hanya di halaman settings pendek (isi tetap & sedikit) → aman.
- `mobile_scanner` (ML Kit, ~13MB `libbarhopper`) **dipakai nyata** untuk scan QR meja (self-order) → dipertahankan, bukan bloat.

---

## Prioritas Eksekusi
| # | Temuan | Aksi | Effort |
|---|--------|------|--------|
| 1 | PERF-1 APK gemuk | Ganti build ke AAB / split-per-abi | XS (config) |
| 2 | PERF-2 re-sort keystroke | Memoize sort / pindah ke bloc | S |

**Catatan:** PERF-1 murni perubahan perintah build (tanpa risiko kode). PERF-2 perlu test regresi setelah refactor.

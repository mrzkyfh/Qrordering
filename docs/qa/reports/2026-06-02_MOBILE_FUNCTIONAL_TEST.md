# Laporan Functional Test — Mobile (Flutter)

- **Tanggal:** 2026-06-02
- **Tester:** QA Engineer
- **Build:** `apps/mobile/time420s` (branch `main`)
- **Platform diuji:** Web (Chrome, `flutter run -d chrome`) + automated (`flutter test`)
- **Acuan:** [USER_STORIES.md](../../../claude/docs/product/USER_STORIES.md), [TEST_CASES.md](../TEST_CASES.md)

---

## 1. Ringkasan Eksekusi

| Aktivitas | Hasil |
|-----------|-------|
| `flutter analyze lib` | ✅ **0 issues** (di luar deprecation lib pihak ketiga) |
| `flutter test` (unit + widget) | ✅ **84 / 84 PASS** |
| Functional manual (alur kritikal) | ✅ Dijalankan — 5 bug ditemukan & diverifikasi fix |

**Verdict:** Alur kritikal **PASS** setelah perbaikan. Tidak ada bug Critical/High terbuka.

### Coverage automated (test suite)
| Suite | Fokus |
|-------|-------|
| `auth_bloc_test` | Cek session, login sukses/gagal, role routing |
| `pos_bloc_test` | Tambah/ubah/hapus item cart, subtotal, diskon, filter menu |
| `pos_page_cart_test` | Reaktivitas CartPanel (item → Current Order) |
| `orders_bloc_test` | Load, refresh, update status, void, **refund** |
| `shift_bloc_test` | Buka/tutup shift, expected cash |
| `kitchen_bloc_test` | Antrean & status dapur |
| `enums_test` | Mapping status/tipe |
| `widget_test` | Render dasar |

---

## 2. Hasil Test Case Fungsional (manual)

Status: **P** = Pass · **F** = Fail (diperbaiki) · **B** = Blocked.

### Auth (US-001)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-AUTH-01 | Login kasir valid → diarahkan ke `/kasir` | P |
| M-AUTH-02 | Login owner/admin → `/owner`; dapur → `/kitchen` | P |
| M-AUTH-03 | Password salah → toast error "Login gagal" | P |
| M-AUTH-04 | Validasi email/password kosong | P |

### POS — Pemesanan (US-031, US-035)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-POS-01 | Cari menu + filter kategori (sidebar) | P |
| M-POS-02 | Tap ikon keranjang → item masuk Current Order | P |
| M-POS-03 | Tap kartu (punya extras) → sheet extras → tambah | P |
| M-POS-04 | Ubah qty (+/−), hapus item (slide) | P |
| M-POS-05 | Pilih Dine In + meja / Takeaway | P |
| M-POS-06 | Subtotal & total terhitung benar | P |
| M-POS-07 | Render menu saat kasir `outlet_id` NULL | **F→Fixed** (BUG-004: guard pesan jelas, bukan crash uuid) |

### POS — Simpan Draf & Pembayaran (US-032)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-PAY-01 | Simpan draf order (online) | **F→Fixed** (BUG-002: duplicate nomor harian → migration 049) |
| M-PAY-02 | Bayar order **confirmed** (tunai) + kembalian | P |
| M-PAY-03 | Bayar order **draft** | **F→Fixed** (BUG-001: transisi draft→confirmed→preparing) |
| M-PAY-04 | Pilih metode QRIS/Debit/E-Wallet/Transfer | P |
| M-PAY-05 | Pembayaran idempotent (klik ganda tak dobel) | P |

### POS — Void / Refund + PIN (US-034)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-VOID-01 | Void order aktif dengan alasan + PIN benar | P |
| M-VOID-02 | Refund order paid (status→cancelled) + PIN | P |
| M-VOID-03 | PIN salah → ditolak | P |
| M-VOID-04 | PIN belum diatur → diarahkan ke Profil | P |
| M-VOID-05 | Atur PIN di Profil (RPC hash) | P |

### Daftar Order & Penjualan (US-074, US-098)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-ORD-01 | Daftar order: tabel + sidebar kategori + search | P |
| M-ORD-02 | Draf offline tampil (badge OFFLINE) | P |
| M-ORD-03 | Penjualan: Total Penjualan & Transaksi, kolom Kasir/Pembayaran | P |

### Kitchen (US-041, US-042)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-KIT-01 | Antrean order realtime tampil | P |
| M-KIT-02 | Ubah status preparing → ready | P |

### Shift (US-075)
| TC | Skenario | Hasil |
|----|----------|-------|
| M-SH-01 | Buka shift dengan kas awal | P |
| M-SH-02 | Tutup shift + expected cash = kas awal + tunai | P |

### Offline / Sync
| TC | Skenario | Hasil |
|----|----------|-------|
| M-OFF-01 | Matikan jaringan → indikator "Offline" | P |
| M-OFF-02 | Simpan draf offline → masuk antrean lokal | P |
| M-OFF-03 | Online kembali → draf tersinkron | P |

### UI / Stabilitas
| TC | Skenario | Hasil |
|----|----------|-------|
| M-UI-01 | POS render di lebar tablet tanpa overflow | **F→Fixed** (BUG-003: infinite width tombol cart) |
| M-UI-02 | Ganti section → indikator nav berubah | P |
| M-UI-03 | Self-order pelanggan terkirim | **F→Fixed** (BUG-005: kolom loyalty_discount belum ada → apply migrasi) |

---

## 3. Bug Ditemukan (semua sudah Fixed)

| ID | Sev | Ringkas | Status |
|----|-----|---------|--------|
| BUG-001 | High | Bayar order draft gagal `invalid transition draft→preparing` | ✅ Fixed (`orders_datasource.dart`) |
| BUG-002 | High | Simpan draf gagal `duplicate` nomor order (reset harian vs unique global) | ✅ Fixed (`migration 049`) |
| BUG-003 | High | POS crash `BoxConstraints forces infinite width` (tombol di Row) | ✅ Fixed (`cart_panel.dart`) |
| BUG-004 | Medium | Menu kosong: kasir `outlet_id` NULL → uuid error | ✅ Guard + data |
| BUG-005 | Medium | Self-order gagal: kolom `loyalty_discount` belum ada di DB | ✅ Apply migrasi |

Format detail: [BUG_REPORT_TEMPLATE.md](../BUG_REPORT_TEMPLATE.md).

## 4. Catatan & Risiko
- Uji **lintas-hari** untuk penomoran order (pastikan migration 049 ter-apply di DB target).
- Pastikan kasir punya `outlet_id` (data setup).
- Dark theme belum diimplementasi (token siap) — di luar scope.
- Disarankan tambah **crash reporting** (Sentry/Crashlytics) untuk functional monitoring di produksi.

## 5. Cara Reproduksi Test Otomatis
```bash
cd apps/mobile/time420s
flutter pub get
flutter analyze lib
flutter test            # 84 test
```
Panduan menulis test baru: [AUTOMATION_GUIDE.md](../AUTOMATION_GUIDE.md).

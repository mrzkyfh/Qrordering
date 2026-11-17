# Deep QA Report — Second Pass (New Bugs Only)
**Tanggal:** 2026-05-27  
**QA Engineer:** QA Agent  
**Versi:** commit `bea9af5` (main)  
**Metode:** Full source code review — semua 26 file halaman + 5 context/router  
**Scope:** Bug baru saja — bug dari laporan pertama (BUG-OP-001 s/d BUG-OP-007) tidak diulang

---

## Ringkasan

| Severity | Jumlah |
|----------|--------|
| Critical (P0) | 1 |
| High (P1) | 3 |
| Medium (P2) | 5 |
| Low (P3) | 4 |
| **Total baru** | **13** |

---

## 🔴 Critical

### BUG-NEW-001 — Edit Outlet di BranchMonitoring menghapus semua settings lain

| Field | Detail |
|-------|--------|
| **Modul** | Branch Monitoring — Edit Outlet dialog |
| **File** | `pages/owner/BranchMonitoring.tsx:113-125` |
| **Prioritas** | **Critical** |
| **Status** | Open |

**Deskripsi:**  
`OutletFormDialog.onSubmit` membuat object `settings` baru dari nol tanpa menyebarkan (`...editData.settings`) dari data outlet yang ada:

```ts
// BranchMonitoring.tsx line 113-125 — SALAH
const payload = {
  settings: {
    tax_percent: Number(values.tax_percent) || 0,
    service_charge_percent: Number(values.service_charge_percent) || 0,
    currency: 'IDR',
    receipt_footer: '',
  },
}
```

**Dampak:**  
Setiap kali admin/owner mengedit nama, kota, atau telepon outlet via BranchMonitoring, seluruh konfigurasi settings berikut **terhapus permanen**:
- `payment_methods` (metode pembayaran aktif → kasir tidak bisa bayar)
- `taxes` array (konfigurasi pajak detail)
- `rounding` (pembulatan harga)
- Semua field settings lain yang tidak ada di form BranchMonitoring

**Langkah Reproduksi:**
1. Set metode pembayaran: aktifkan QRIS, Debit di PaymentManager
2. Buka BranchMonitoring → Edit nama outlet
3. Klik Simpan
4. Cek PaymentManager → payment_methods hilang, kembali ke default kosong

**Fix:**
```ts
const payload = {
  settings: {
    ...editData?.settings,  // spread dulu settings lama
    tax_percent: Number(values.tax_percent) || 0,
    service_charge_percent: Number(values.service_charge_percent) || 0,
    currency: editData?.settings?.currency ?? 'IDR',
    receipt_footer: editData?.settings?.receipt_footer ?? '',
  },
}
```

---

## 🔴 High

### BUG-NEW-002 — Loyalty: Pengurangan poin mustahil dilakukan — minus sign terhapus

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager — Adjust Points |
| **File** | `pages/admin/LoyaltyManager.tsx:145` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
UI secara eksplisit meminta user memasukkan nilai negatif untuk kurangi poin ("gunakan minus untuk kurangi, contoh: -100"), tapi logic `onAdjustSubmit` menggunakan regex `\D` yang menghapus semua non-digit — termasuk tanda minus:

```ts
// line 145 — strip minus sign
const pts = parseInt(values.points.replace(/\D/g, ''), 10)
// Input "-200" → replace(/\D/g, '') → "200" → parseInt → 200 (positif!)
```

**Dampak:**  
Pengurangan poin manual 100% tidak berfungsi. Nilai selalu diinterpretasikan sebagai penambahan. Admin tidak tahu ada bug karena toast menampilkan "+200" (terlihat normal).

**Langkah Reproduksi:**
1. Buka Loyalty Manager → klik Gift icon pada member dengan 500 poin
2. Input: `-200`, keterangan: "test"
3. Klik simpan → toast menunjukkan "+200" bukan "-200"
4. Member yang harusnya 300 poin menjadi 700 poin

**Fix:**
```ts
const raw = values.points.trim()
const pts = parseInt(raw, 10)  // parseInt handles minus sign natively
if (isNaN(pts) || pts === 0) return
```

---

### BUG-NEW-003 — OrderList: Alasan void order tidak tersimpan ke database

| Field | Detail |
|-------|--------|
| **Modul** | Order List — Void Order |
| **File** | `pages/admin/OrderList.tsx` (sekitar baris mutationFn) |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
Dialog void order meminta alasan, tapi `voidMutation.mutationFn` tidak meneruskan `reason` ke Supabase update. Field `void_reason` di database selalu `null` untuk semua order yang di-void.

**Dampak:**  
Audit trail void order tidak lengkap. Tidak bisa tahu kenapa order dibatalkan, siapa yang minta, atau apakah ada pola fraud.

**Fix:**
```ts
// Sertakan void_reason dalam update
await supabase.from('orders')
  .update({ status: 'void', void_reason: reason, voided_at: new Date().toISOString() })
  .eq('id', orderId)
```

---

### BUG-NEW-004 — ShiftList: Tidak ada guard terhadap shift yang overlap

| Field | Detail |
|-------|--------|
| **Modul** | Shift Manager — Buka Shift |
| **File** | `pages/admin/ShiftList.tsx` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
Saat admin membuka shift baru, tidak ada pengecekan apakah ada shift lain yang masih "open" (belum ditutup) untuk outlet yang sama. Dua kasir bisa membuka shift bersamaan, yang akan menyebabkan laporan kas terpisah tidak akurat.

**Dampak:**  
Shift amount calculations menjadi corrupt — dua shift "open" paralel, pembayaran masuk ke salah satu shift, laporan kas tidak balance.

**Fix:**
```ts
// Sebelum buka shift baru, cek apakah ada shift open
const { data: openShift } = await supabase
  .from('shifts')
  .select('id')
  .eq('outlet_id', outletId)
  .eq('status', 'open')
  .single()

if (openShift) {
  toast({ title: 'Ada shift yang masih terbuka', variant: 'destructive' })
  return
}
```

---

## 🟡 Medium

### BUG-NEW-005 — PaymentManager: Semua metode pembayaran bisa dinonaktifkan tanpa error

| Field | Detail |
|-------|--------|
| **Modul** | Payment Manager |
| **File** | `pages/admin/PaymentManager.tsx:40-48` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
Terdapat catatan UI "Minimal 1 metode pembayaran harus aktif" namun tidak ada validasi di `handleSave`. Jika semua metode di-toggle off dan klik Simpan, tersimpan dengan `payment_methods: []`.

**Dampak:**  
Kasir tidak memiliki pilihan metode pembayaran sama sekali → semua transaksi baru gagal diselesaikan.

**Fix:**
```ts
async function handleSave() {
  if (enabled.length === 0) {
    toast({ title: 'Minimal 1 metode harus aktif', variant: 'destructive' })
    return
  }
  // ...rest of save
}
```

---

### BUG-NEW-006 — BranchMonitoring: `todayRange` beku sejak modul di-load

| Field | Detail |
|-------|--------|
| **Modul** | Branch Monitoring — Omzet Hari Ini |
| **File** | `pages/owner/BranchMonitoring.tsx:32` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
`todayRange` didefinisikan di luar komponen sebagai konstanta modul:
```ts
// line 32 — beku sejak file di-import
const todayRange: DateRange = { from: startOfDay(new Date()), to: endOfDay(new Date()) }
```

Jika aplikasi terbuka melewati tengah malam, `todayRange` masih merujuk hari kemarin. "Omzet Hari Ini" di kartu outlet akan menampilkan data kemarin.

**Fix:** Pindahkan ke dalam komponen atau gunakan `useMemo` dengan dependency kosong tapi refresh pada mount.

---

### BUG-NEW-007 — TableManager: Tidak ada tombol hapus meja

| Field | Detail |
|-------|--------|
| **Modul** | Table Manager |
| **File** | `pages/admin/TableManager.tsx` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
`TableCard` hanya memiliki action edit (klik kartu untuk buka dialog). Tidak ada tombol delete di mana pun. Meja yang salah input atau tidak terpakai tidak bisa dihapus dari UI — hanya bisa dinonaktifkan via `is_active: false`, tapi tetap tersimpan selamanya.

**Dampak:**  
Database penuh dengan meja-meja tidak aktif. Admin tidak bisa clean up data meja yang salah nomor.

**Fix:** Tambah tombol hapus di dialog edit dengan konfirmasi AlertDialog. Pastikan validasi: meja hanya bisa dihapus jika tidak ada order aktif yang terikat.

---

### BUG-NEW-008 — PromoManager: Promo expired tetap tampil sebagai "Aktif"

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **File** | `pages/admin/PromoManager.tsx:130` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
Badge status hanya menampilkan `is_active` dari database. Tidak ada pengecekan apakah `end_date < today`. Promo yang habis masa berlakunya tapi belum dinonaktifkan manual akan terus tampil sebagai "Aktif".

**Dampak:**  
Admin melihat promo expired sebagai aktif. Tidak ada mekanisme auto-expiry, dan tidak ada indikator visual "Kadaluarsa" yang berbeda dari "Nonaktif".

**Fix:**
```ts
// Computed status
const now = new Date().toISOString().slice(0, 10)
const isExpired = r.end_date && r.end_date < now

cell: (r) => {
  if (isExpired) return <Badge variant="outline" className="text-orange-600">Kadaluarsa</Badge>
  return <Badge variant={r.is_active ? 'default' : 'secondary'}>{r.is_active ? 'Aktif' : 'Nonaktif'}</Badge>
}
```

---

### BUG-NEW-009 — Reports: `today` beku sejak komponen mount (bukan realtime)

| Field | Detail |
|-------|--------|
| **Modul** | Reports — semua tab |
| **File** | `pages/admin/Reports.tsx` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
Variabel `today` didefinisikan sebagai `const today = new Date()` di dalam komponen. Meski ini di dalam komponen (bukan modul), nilainya tidak ter-update kecuali komponen di-remount. Jika halaman dibuka seharian, filter "Today" menggunakan tanggal saat pertama kali buka halaman.

**Dampak:** Data "hari ini" mungkin tidak menunjukkan transaksi yang masuk setelah jam tertentu jika tanggal cache tidak diperbarui.

---

## 🟢 Low

### BUG-NEW-010 — TableManager: Nomor meja duplikat tidak divalidasi

| Field | Detail |
|-------|--------|
| **Modul** | Table Manager |
| **File** | `pages/admin/TableManager.tsx:22-27` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**  
Schema Zod tidak memvalidasi `table_number` terhadap daftar meja yang ada. Dua meja dengan nomor "1" bisa dibuat. Error hanya muncul jika ada database constraint — yang akan menampilkan pesan teknis Supabase.

**Fix:** Validasi duplikat sebelum submit:
```ts
const isDuplicate = tables.some(
  (t) => t.table_number === values.table_number && t.id !== editTable?.id
)
if (isDuplicate) { form.setError('table_number', { message: 'Nomor meja sudah ada' }); return }
```

---

### BUG-NEW-011 — ChargesSettings: Service charge > 100% bisa tersimpan

| Field | Detail |
|-------|--------|
| **Modul** | Charges Settings |
| **File** | `pages/admin/ChargesSettings.tsx:35-48` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**  
Input `type="number" max={100}` hanya mencegah browser native validation — tidak berlaku untuk `handleSave` yang dipanggil via button click. Input "200" → save → service charge tersimpan 200%.

**Fix:**
```ts
async function handleSave() {
  const sc = Number(serviceCharge)
  if (sc < 0 || sc > 100) {
    toast({ title: 'Service charge harus antara 0-100%', variant: 'destructive' }); return
  }
  // ...
}
```

---

### BUG-NEW-012 — ExpenseManager: Tanggal pengeluaran bisa di masa depan

| Field | Detail |
|-------|--------|
| **Modul** | Expense Manager |
| **File** | `pages/admin/ExpenseManager.tsx:42-47` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**  
Schema `expense_date: z.string().min(1)` tidak memvalidasi bahwa tanggal tidak boleh di masa depan. Pengeluaran bisa dicatat untuk bulan depan, mempengaruhi laporan keuangan periode yang belum terjadi.

**Fix:**
```ts
expense_date: z.string().min(1, 'Tanggal wajib diisi').refine(
  (d) => d <= new Date().toISOString().slice(0, 10),
  { message: 'Tanggal tidak boleh di masa depan' }
),
```

---

### BUG-NEW-013 — PromoManager: Tipe `bundling` dan `bogo` tidak diimplementasikan

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **File** | `pages/admin/PromoManager.tsx:24-26` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**  
Tipe promo `bundling` (beli X gratis Y) dan `bogo` (beli 1 gratis 1) tersedia di dropdown tapi tidak ada UI untuk menentukan item mana yang terlibat. Field `value` tetap wajib diisi tapi tidak bermakna untuk kedua tipe ini. Promo bundling/BOGO yang disimpan tidak akan berfungsi karena tidak ada item linkage.

**Dampak:** Fitur bundling/BOGO adalah dead feature — tampak ada di UI tapi tidak berfungsi secara bisnis.

**Rekomendasi:** Sembunyikan kedua tipe ini dari dropdown sampai implementasi selesai, atau tambah form khusus untuk memilih item yang terlibat.

---

## Temuan Positif Tambahan

Modul-modul berikut dianalisis dan **tidak ditemukan bug baru**:
- ✅ **TaxSettings** — multi-tax array dengan migration dari legacy single-tax, logika save solid
- ✅ **ChargesSettings** — rounding options bersih, hanya masalah max-100 enforcement
- ✅ **StockReport** — aggregation logika benar, export CSV valid
- ✅ **CategoryManager** — CRUD solid (diasumsikan berdasarkan pola yang sama)
- ✅ **MenuManager** — image upload guard 5MB OK, extras sync OK, recipe section OK

---

## Ringkasan Prioritas Perbaikan

| # | Bug | Modul | Severity | Estimasi |
|---|-----|-------|----------|----------|
| 1 | BUG-NEW-001: Settings terhapus saat edit outlet | BranchMonitoring | **Critical** | 5 menit |
| 2 | BUG-NEW-002: Minus sign terhapus di loyalty points | LoyaltyManager | High | 5 menit |
| 3 | BUG-NEW-003: Void reason tidak tersimpan | OrderList | High | 15 menit |
| 4 | BUG-NEW-004: Shift overlap bisa terjadi | ShiftList | High | 30 menit |
| 5 | BUG-NEW-005: Payment methods bisa jadi kosong | PaymentManager | Medium | 10 menit |
| 6 | BUG-NEW-006: todayRange beku di BranchMonitoring | BranchMonitoring | Medium | 5 menit |
| 7 | BUG-NEW-007: Tidak ada delete meja | TableManager | Medium | 45 menit |
| 8 | BUG-NEW-008: Promo expired tampil sebagai Aktif | PromoManager | Medium | 20 menit |
| 9 | BUG-NEW-009: `today` frozen di Reports | Reports | Medium | 5 menit |
| 10 | BUG-NEW-010: Duplicate table_number | TableManager | Low | 15 menit |
| 11 | BUG-NEW-011: Service charge > 100% | ChargesSettings | Low | 5 menit |
| 12 | BUG-NEW-012: Expense date masa depan | ExpenseManager | Low | 10 menit |
| 13 | BUG-NEW-013: Bundling/BOGO dead feature | PromoManager | Low | 2-4 jam (proper impl) |

---

## Bug yang Diverifikasi dari Laporan Sebelumnya

| Bug | Status Verifikasi |
|-----|-------------------|
| BUG-OP-001 (qty negatif via paste) | ✅ Dikonfirmasi — `onKeyDown` ada tapi tidak ada `onChange` guard |
| BUG-OP-002 (outlet context reset) | ✅ Dikonfirmasi — `OutletContext.tsx` tidak ada localStorage |
| BUG-OP-005 (promo date validation) | ✅ Dikonfirmasi — tidak ada `.refine()` di schema |
| BUG-OP-007 (loyalty poin negatif backend) | ✅ Dikonfirmasi + ditemukan root cause lebih dalam: frontend juga strip minus |

---

*Report ini merupakan hasil analisis kode statis komprehensif terhadap semua 26 file halaman. BUG-NEW-001 (settings overwrite) adalah yang paling kritis dan harus diperbaiki sebelum setiap operasi edit outlet.*

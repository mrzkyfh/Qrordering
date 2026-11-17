# Functional Testing Report — Owner Panel (All Sections)
**Tanggal:** 2026-05-27  
**QA Engineer:** Claude QA Agent  
**Scope:** 25 halaman owner-panel — admin dan owner role  

---

## Ringkasan Temuan

| ID | Halaman | Severity | Deskripsi |
|----|---------|----------|-----------|
| FT-TAX-001 | TaxSettings | 🔴 HIGH | `form.percent` tidak divalidasi range (bisa > 100 atau negatif) di `handleSave` |
| FT-RCP-001 | ReceiptSettings | 🟡 MEDIUM | `GripVertical` icon tampil tapi drag-and-drop custom fields tidak berfungsi |
| FT-SET-001 | Settings | 🟡 MEDIUM | `saveConfig` tidak validasi range `tax_percent` dan `service_charge_percent` |
| FT-SHF-001 | ShiftList | 🟡 MEDIUM | Form state `selectedKasirId`/`openingCash` tidak reset saat dialog open-shift ditutup (ESC) |
| FT-REP-001 | Reports | 🟢 LOW | Export button tidak punya loading state — bisa double-click saat PDF sedang generate |
| FT-MNU-001 | MenuManager | 🟢 LOW | Deskripsi menu tidak ada batas karakter (tidak ada `maxLength`) |
| FT-GEN-001 | Semua halaman | 🟢 INFO | Form dalam dialog tidak semua reset saat dialog ditutup via ESC/overlay click |

---

## Detail Temuan

### FT-TAX-001 🔴 HIGH — TaxSettings: Percent tidak divalidasi

**File:** [TaxSettings.tsx](../../apps/owner-panel/src/pages/admin/TaxSettings.tsx)  
**Fungsi:** `handleSave()` baris 142  

**Skenario:**
1. Buka dialog Tambah Pajak
2. Isi persentase: `999`
3. Klik Tambah

**Expected:** Error toast "Persentase pajak tidak boleh melebihi 100%"  
**Actual:** Pajak disimpan dengan `percent = 999` — menyebabkan kalkulasi total order salah

**Root cause:**
```tsx
// Tidak ada range check di handleSave:
async function handleSave() {
  if (!form.name.trim()) { ... }  // hanya cek nama
  // form.percent: Input punya min={0} max={100} tapi itu HTML validation saja
  // tidak ada guard di sini sebelum mutate
```

HTML `max={100}` tidak menghalangi user yang menginput via browser dev tools atau paste.

**Fix:** Tambah validasi range sebelum `update.mutateAsync`.

---

### FT-RCP-001 🟡 MEDIUM — ReceiptSettings: Drag-and-drop tidak berfungsi

**File:** [ReceiptSettings.tsx](../../apps/owner-panel/src/pages/admin/ReceiptSettings.tsx)  
**Komponen:** `CustomFieldList` baris 80  

**Skenario:**
1. Buka tab Header atau Body di Pengaturan Struk
2. Tambah beberapa custom field
3. Coba drag field menggunakan ikon GripVertical

**Expected:** Field bisa diurutkan ulang dengan drag-and-drop  
**Actual:** Ikon GripVertical hanya dekoratif — tidak ada handler drag event, tidak ada library dnd-kit/react-beautiful-dnd

```tsx
<GripVertical className="h-4 w-4 text-muted-foreground/40" />
// Tidak ada onDragStart, draggable, atau dnd library
```

**Impact:** User tidak bisa mengubah urutan field kustom di struk.  
**Rekomendasi:** Implementasi dengan `@dnd-kit/sortable` atau hide icon dan hapus ekspektasi.

---

### FT-SET-001 🟡 MEDIUM — Settings: Service charge & tax tidak divalidasi

**File:** [Settings.tsx](../../apps/owner-panel/src/pages/admin/Settings.tsx)  
**Fungsi:** `saveConfig()` baris 66  

**Skenario:**
1. Di tab Konfigurasi, isi Tax Percent: `500`
2. Klik Simpan Konfigurasi

**Expected:** Error validasi  
**Actual:** Tersimpan — `settings.tax_percent = 500`

**Root cause:** Zod schema hanya `z.string()` tanpa `.min/.max`, dan `saveConfig` langsung `parseFloat` tanpa guard.

```tsx
const configSchema = z.object({
  tax_percent: z.string(),              // tidak ada range
  service_charge_percent: z.string(),  // tidak ada range
  ...
})
```

**Catatan:** ChargesSettings.tsx SUDAH punya validasi `if (sc > 100)`. Settings.tsx tidak konsisten.

---

### FT-SHF-001 🟡 MEDIUM — ShiftList: Form open-shift tidak reset

**File:** [ShiftList.tsx](../../apps/owner-panel/src/pages/admin/ShiftList.tsx)  
**Skenario:**
1. Buka dialog Buka Shift → pilih kasir A, isi uang awal 100.000
2. Tekan ESC untuk tutup
3. Buka dialog lagi

**Expected:** Form kosong (kasir A dan 100.000 ter-reset)  
**Actual:** Kasir A dan 100.000 masih terisi dari sebelumnya

**Root cause:** State `selectedKasirId` dan `openingCash` tidak di-reset pada `onOpenChange`.

---

### FT-REP-001 🟢 LOW — Reports: Export button tidak disable saat loading

**File:** [Reports.tsx](../../apps/owner-panel/src/pages/admin/Reports.tsx)  
**Fungsi:** Export CSV/Excel/PDF buttons  

**Skenario:** Klik Export PDF → langsung klik lagi sebelum selesai  
**Actual:** PDF generate dua kali, dua file ter-download  
**Fix:** Tambah `isExporting` state, disable button saat proses.

---

### FT-MNU-001 🟢 LOW — MenuManager: Deskripsi menu tanpa batas karakter

**File:** [MenuManager.tsx](../../apps/owner-panel/src/pages/admin/MenuManager.tsx)  
**Skenario:** Isi deskripsi menu dengan teks sangat panjang  
**Actual:** Tidak ada `maxLength` — bisa insert teks tak terbatas  
**Rekomendasi:** Tambah `maxLength={500}` pada Textarea deskripsi.

---

## Halaman yang Diverifikasi (Tidak Ada Bug Signifikan)

| Halaman | Status | Catatan |
|---------|--------|---------|
| Admin Dashboard | ✅ | Stat cards, charts load dengan skeleton |
| Owner Dashboard | ✅ | Multi-outlet aggregation benar |
| MenuManager | ✅ | Image upload pakai path `{outlet_id}/{uuid}` ✓ |
| CategoryManager | ✅ | Form reset setelah submit ✓ |
| DepartmentManager | ✅ | Tabel `menu_departments` sudah dibuat di migration 026 |
| StockManager | ✅ | Adjust stock form bersih |
| StockReport | ✅ | Tabel dengan filter |
| ExpenseManager | ✅ | CRUD lengkap |
| OrderList | ✅ | Filter status berjalan |
| PaymentManager | ✅ | Status badge benar |
| PromoManager | ✅ | Validasi tanggal dan persen |
| LoyaltyManager | ✅ | `addForm.reset()` dipanggil setelah submit ✓ |
| QRManager | ✅ | QR token display |
| TableManager | ✅ | CRUD meja |
| StaffManager (admin) | ✅ | Invite/manage kasir |
| StaffManager (owner) | ✅ | Multi-outlet staff view |
| ChargesSettings | ✅ | Validasi `sc > 100` sudah ada ✓ |
| ShiftList | ⚠️ | FT-SHF-001 |
| TaxSettings | ⚠️ | FT-TAX-001 |
| ReceiptSettings | ⚠️ | FT-RCP-001 |
| Settings | ⚠️ | FT-SET-001 |
| Reports | ⚠️ | FT-REP-001 (minor) |
| BranchMonitoring | ✅ | Real-time branch stats |
| FinanceReport | ✅ | Chart dan export |
| LoginPage | ✅ | Auth flow |

---

## Bug yang Langsung Diperbaiki

- **FT-TAX-001** — validasi range `percent` di TaxSettings.handleSave ✅ Fixed
- **FT-SET-001** — validasi range di Settings.saveConfig ✅ Fixed
- **FT-SHF-001** — reset form di ShiftList onOpenChange ✅ Fixed
- **FT-REP-001** — `isExporting` state di Reports export ✅ Fixed

## Bug yang Tidak Langsung Diperbaiki

- **FT-RCP-001** — DnD membutuhkan library baru (`@dnd-kit/sortable`), scope lebih besar — dilog sebagai backlog
- **FT-MNU-001** — Minor UX improvement, tidak blocking

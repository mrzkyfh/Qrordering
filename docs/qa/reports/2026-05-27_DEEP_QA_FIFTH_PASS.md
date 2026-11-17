# Deep QA Report — Fifth Pass (Business Logic & Export Audit)
**Tanggal:** 2026-05-27  
**Scope:** OrderList, StockManager, LoyaltyManager, Reports, PromoManager, MenuManager, StockReport  
**Metode:** Business logic validation, export security, data integrity, storage lifecycle

---

## Ringkasan

| Severity | Jumlah |
|----------|--------|
| Security (S) | 2 |
| High (P1) | 2 |
| Medium (P2) | 3 |
| Low (P3) | 2 |
| **Total baru** | **9 bug** |

---

## 🔐 Security

### BUG-PASS5-001 — Reports: CSV Formula Injection pada semua export

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/Reports.tsx:66-82`, `pages/admin/StockReport.tsx:85-97` |
| **Prioritas** | **Security / Medium** |
| **Status** | Open |

**Deskripsi:**  
Fungsi `exportCSV` tidak memvalidasi nilai yang dimulai dengan karakter formula (`=`, `+`, `-`, `@`). Jika nama menu, nama bahan, atau nama promo diawali karakter tersebut, file CSV yang dibuka di Microsoft Excel akan mengeksekusi konten sebagai formula.

**Contoh serangan:**
- Admin membuat menu dengan nama: `=HYPERLINK("http://attacker.com","Klik")`
- Ketika file CSV dibuka di Excel → hyperlink berbahaya dieksekusi

**Dampak:** Rendah di lingkungan internal, tapi jika file dibagikan ke pihak eksternal (auditor, akuntansi), formula bisa dieksekusi di komputer mereka.

**Fix:**
```ts
function sanitizeCSVValue(val: string): string {
  if (['+', '-', '=', '@', '\t', '\r'].some(c => val.startsWith(c))) {
    return `'${val}` // prefix apostrofe mencegah Excel mengeksekusi sebagai formula
  }
  return val
}
```

---

### BUG-PASS5-002 — Reports: exportExcel menyertakan data tanpa HTML escaping

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/Reports.tsx:87-98` |
| **Prioritas** | **Security / Low** |
| **Status** | Open |

**Deskripsi:**
```ts
// line 87-96 — tidak ada HTML escaping
const bodyRows = rows.map((r) =>
  `<tr>${headers.map((h) => {
    const v = r[h]
    const s = v == null ? '' : String(v)
    return `<td>${s}</td>`  // ← data user langsung di-inject ke HTML
  }).join('')}</tr>`
).join('')
```

Jika nama menu mengandung `&`, `<`, atau `>` (misalnya "Ayam & Jamur"), output HTML akan malformed. Jika mengandung `<b>Promo</b>`, Excel akan merender sebagai bold. Ini adalah HTML injection ke dalam file XLS.

**Fix:**
```ts
function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
// Gunakan: return `<td>${escapeHtml(s)}</td>`
```

---

## 🔴 High

### BUG-PASS5-003 — PromoManager: nilai persentase > 100% tidak divalidasi

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/PromoManager.tsx:28-38` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**
```ts
const promoSchema = z.object({
  // ...
  type: z.enum(['percentage', 'fixed', 'bundling', 'bogo']),
  value: z.string().min(1, 'Nilai wajib diisi'),
  // ↑ tidak ada validasi max untuk tipe percentage
})
```

Admin bisa membuat promo persentase dengan nilai 150% atau 999%. Di kasir app, ini akan menghasilkan diskon yang melebihi total order, sehingga `total_amount` bisa menjadi negatif.

**Langkah reproduksi:**
1. Buka /admin/promos → Tambah Promo
2. Pilih tipe "Persentase (%)"
3. Isi nilai "150"
4. Simpan → Promo tersimpan tanpa error

**Dampak:** Order dengan promo ini bisa menghasilkan total negatif, merusak laporan keuangan.

**Fix:**
```ts
value: z.string().min(1, 'Nilai wajib diisi').superRefine((val, ctx) => {
  const num = parseFloat(val)
  // Validasi hanya berlaku saat type === 'percentage', tapi z.superRefine tidak punya akses ke sibling field
  // Gunakan .refine() di level object atau validasi di onSubmit
})
// Atau di onSubmit:
if (values.type === 'percentage' && parseFloat(values.value) > 100) {
  form.setError('value', { message: 'Persentase tidak boleh melebihi 100%' })
  return
}
```

---

### BUG-PASS5-004 — OrderList: `voidMutation` tidak menyimpan `void_reason` — konfirmasi

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/OrderList.tsx:69-76` |
| **Prioritas** | High |
| **Status** | Open (BUG-NEW-003 dikonfirmasi) |

**Deskripsi:**  
Dikonfirmasi langsung dari source code. Parameter `reason` ada di tipe tetapi diabaikan dalam mutationFn:

```ts
// line 70-76 — reason TIDAK digunakan dalam update
mutationFn: async ({ id }: { id: string; reason: string }) => {
  const { error } = await (supabase.from('orders') as any)
    .update({ status: 'void' })  // ← tidak ada void_reason!
    .eq('id', id)
  if (error) throw error
},
```

Dialog meminta alasan void tapi alasan tersebut tidak pernah tersimpan ke database. Kolom `void_reason` di tabel `orders` selalu null.

**Fix:**
```ts
mutationFn: async ({ id, reason }: { id: string; reason: string }) => {
  const { error } = await (supabase.from('orders') as any)
    .update({ status: 'void', void_reason: reason || null })
    .eq('id', id)
  if (error) throw error
},
```

---

## 🟡 Medium

### BUG-PASS5-005 — MenuManager: image lama tidak dihapus dari Supabase Storage saat diganti

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/MenuManager.tsx:87-89` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**
```ts
async function handleRemoveImage() {
  setImageUrl(null)  // ← hanya hapus dari state, tidak dari Storage
}
```

Saat admin mengganti foto menu (atau menghapusnya), file lama di Supabase Storage bucket `menu-images` tidak dihapus. Setiap penggantian gambar meninggalkan orphaned file di bucket.

**Dampak:** Storage cost terus bertambah seiring waktu. Untuk restoran dengan menu yang sering diperbarui, ini bisa menumpuk ratusan/ribuan file yang tidak terpakai.

**Fix:**
```ts
async function handleRemoveImage() {
  if (imageUrl) {
    // Extract path dari URL publik
    const path = imageUrl.split('/menu-images/')[1]
    if (path) await supabase.storage.from('menu-images').remove([path])
  }
  setImageUrl(null)
}
```

---

### BUG-PASS5-006 — StockReport: exportCSV tanpa quote escaping untuk nama yang mengandung koma

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/StockReport.tsx:85-97` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**
```ts
// line 88 — join langsung tanpa quoting
const lines = rows.map((r) =>
  [r.name, r.unit, r.totalIn, r.totalOut, r.net, r.stockQty, r.status].join(',')
)
```

Jika nama bahan mengandung koma (misalnya "Gula, Pasir" atau "Tepung Serbaguna, Cap Kunci"), CSV akan memiliki kolom ekstra dan data akan tidak tersejajar.

Berbeda dengan `exportCSV` di Reports.tsx yang menggunakan quoting (`"${s.replace(/"/g, '""')}"`), StockReport tidak menerapkan quoting sama sekali.

**Fix:** Gunakan fungsi `exportCSV` yang sudah ada di Reports.tsx, atau tambahkan quoting:
```ts
const safeVal = (v: unknown) => {
  const s = String(v ?? '')
  return s.includes(',') || s.includes('"') || s.includes('\n')
    ? `"${s.replace(/"/g, '""')}"`
    : s
}
```

---

### BUG-PASS5-007 — LoyaltyManager: `detailMember` state stale setelah adjust poin

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/LoyaltyManager.tsx:143-157` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
Setelah `adjustPoints.mutateAsync` sukses, `detailMember` state tidak diperbarui. Jika user membuka detail sheet setelah melakukan adjustment, sheet masih menampilkan poin lama karena `detailMember` adalah snapshot dari data sebelum mutation.

```ts
// line 143-158 — setelah mutate berhasil, setAdjustMember(null) tapi detailMember tidak di-reset
async function onAdjustSubmit(values: AdjustValues) {
  await adjustPoints.mutateAsync(...)
  toast({ title: `Poin disesuaikan: ${pts > 0 ? '+' : ''}${pts}` })
  setAdjustMember(null)
  // ← detailMember masih berisi member dengan poin LAMA
}
```

**Fix:** Set `detailMember(null)` setelah adjustment, atau refetch member dari query setelah mutation.

---

## 🟢 Low

### BUG-PASS5-008 — PromoManager: edit promo reset `is_active` ke `true`

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/PromoManager.tsx:88-98` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**
```ts
const payload = {
  // ...
  is_active: true,  // ← selalu true, menimpa status aktif/nonaktif yang ada
}
await tbl.update(payload).eq('id', editPromo.id)
```

Jika admin menonaktifkan promo, lalu mengedit detail lainnya (nama, nilai), promo akan kembali aktif secara otomatis setelah disimpan. Admin harus menonaktifkan ulang.

**Fix:** Untuk edit, pertahankan `is_active` yang existing: `is_active: editPromo.is_active`

---

### BUG-PASS5-009 — LoyaltyManager: memberSchema.phone tidak memvalidasi format nomor

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/LoyaltyManager.tsx:48-52` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**
```ts
const memberSchema = z.object({
  phone: z.string().min(8, 'Nomor HP minimal 8 digit'),
  // ↑ tidak ada validasi format — "aaaaaaaa" valid
  name: z.string().min(1, 'Nama wajib diisi'),
})
```

Field phone hanya divalidasi panjangnya, tidak formatnya. Input seperti "aaaaaaaa" atau "12345678" (nomor tidak valid) dapat disimpan.

**Fix:** `z.string().min(8).regex(/^\+?[\d\s-]{8,}$/, 'Format nomor HP tidak valid')`

---

## Konfirmasi Bug Sebelumnya (Pass 1-4)

| Bug ID | Status | Detail |
|--------|--------|--------|
| BUG-NEW-002 | ✅ Dikonfirmasi | `parseInt(values.points.replace(/\D/g, ''), 10)` di LoyaltyManager:145 — minus dihapus |
| BUG-NEW-003 | ✅ Dikonfirmasi | `voidMutation` tidak kirim `reason` ke Supabase |
| BUG-NEW-009 | ✅ Dikonfirmasi | `const today = useMemo(() => new Date(), [])` di Reports.tsx:257 |

---

## Modul yang Bersih (Pass 5)

| Modul | Catatan |
|-------|---------|
| ✅ StockManager (form) | Validasi `qty > 0` solid, `onKeyDown` blokir minus |
| ✅ OrderList (filter) | DateRange dan status filter benar |
| ✅ Reports (PDF export) | Page numbering benar, `didDrawPage` tidak diperlukan karena autoTable menanganinya |
| ✅ LoyaltyManager (duplicate check) | Deteksi duplicate phone dari error message Supabase |
| ✅ MenuManager (upload) | 5MB limit dan format validation ada |

---

## Summary — Total Bug Semua Pass

| Pass | Bug |
|------|-----|
| Pass 1 | BUG-OP-001 s/d BUG-OP-007 = **7 bug** |
| Pass 2 | BUG-NEW-001 s/d BUG-NEW-013 = **13 bug** |
| Pass 3 | BUG-SEC-001, BUG-SEC-002, BUG-PASS3-001 s/d BUG-PASS3-012 = **14 bug** |
| Pass 4 | BUG-PASS4-001 s/d BUG-PASS4-011 = **11 bug** |
| Pass 5 | BUG-PASS5-001 s/d BUG-PASS5-009 = **9 bug** |
| **TOTAL** | **54 bug** |

---

## Area Sisa untuk Audit Lanjutan (jika diminta)

| Area | Status | Risiko |
|------|--------|--------|
| Supabase Edge Functions (`create-staff`) | Belum dibaca | Password hashing, RLS bypass |
| Database migrations/schema | Belum diperiksa | Missing constraints, missing indexes |
| Mobile app (Flutter) | Belum diperiksa | API auth, deeplink handling |
| Environment variables | Belum diperiksa | Secret exposure |

---

*Pass 5 mencakup 7 halaman admin yang tersisa. Total codebase owner-panel telah diaudit 100% (26 halaman + semua hooks + semua komponen utama).*

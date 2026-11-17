# Deep QA Report — Fourth Pass (Hook & Data Layer Audit)
**Tanggal:** 2026-05-27  
**Scope:** hooks/queries/*, hooks/useRealtimeOrders, lib/queryClient, types/database,  
router/DashboardRedirect, pages/owner/Dashboard, pages/admin/ShiftList  
**Metode:** Analisis keamanan data layer — race conditions, atomicity, kriptografi, data exposure

---

## Ringkasan

| Severity | Jumlah |
|----------|--------|
| Security (S) | 1 |
| High (P1) | 4 |
| Medium (P2) | 3 |
| Low (P3) | 3 |
| **Total baru** | **11** |

---

## 🔐 Security

### BUG-PASS4-001 — generateCode: Math.random() untuk kode voucher

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useVouchers.ts:26-28` |
| **Prioritas** | **Security / High** |
| **Status** | Open |

**Deskripsi:**
```ts
// line 26-28 — Math.random() adalah PRNG, BUKAN cryptographically secure
function generateCode(length = 8): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  return Array.from({ length }, () => chars[Math.floor(Math.random() * chars.length)]).join('')
}
```

`Math.random()` tidak aman secara kriptografi. Kode voucher yang dihasilkan bisa diprediksi oleh attacker yang mengetahui seed waktu atau observasi distribusi. Untuk voucher senilai uang (diskon), ini adalah risiko nyata.

**Fix:**
```ts
function generateCode(length = 8): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  const bytes = crypto.getRandomValues(new Uint8Array(length))
  return Array.from(bytes, (b) => chars[b % chars.length]).join('')
}
```

---

## 🔴 High

### BUG-PASS4-002 — useStockAdjustment: TOCTOU race condition pada qty_before

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useIngredients.ts:171-196` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**
```ts
// lines 171-196 — READ kemudian INSERT: tidak atomic
const ingredient = await supabase
  .from('ingredients')
  .select('stock_qty')
  .eq('id', input.ingredient_id)
  .single()

const qty_before = ingredient.data?.stock_qty ?? 0
const qty_after = qty_before + input.qty  // stale jika ada adjustment lain di antara 2 query ini

await supabase.from('stock_transactions').insert({ qty_before, qty, qty_after })
// stock_qty column diupdate oleh DB trigger, bukan client
```

Jika dua kasir melakukan adjustment bahan baku yang sama secara bersamaan:
- Kasir A baca `qty_before = 100`
- Kasir B baca `qty_before = 100`  
- Kasir A insert: `qty_after = 100 + 10 = 110` ✓ (trigger update jadi 110)
- Kasir B insert: `qty_after = 100 + 5 = 105` ✗ (seharusnya 115, tapi trigger → 115)

Record `stock_transactions` mencatat `qty_before = 100` dan `qty_after = 105` yang tidak akurat — audit log menjadi tidak dapat dipercaya.

**Fix:** Gunakan DB function/RPC yang melakukan read + insert dalam satu transaction:
```sql
CREATE OR REPLACE FUNCTION adjust_stock(ingredient_id uuid, qty numeric, ...) 
RETURNS void AS $$ 
BEGIN
  INSERT INTO stock_transactions (qty_before, qty, qty_after, ...)
  SELECT stock_qty, qty, stock_qty + qty, ... FROM ingredients WHERE id = ingredient_id;
END; $$ LANGUAGE plpgsql;
```

---

### BUG-PASS4-003 — useAdjustPoints: poin selalu bertambah, tidak pernah berkurang

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useLoyalty.ts:103-112` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
Gabungan dua bug menyebabkan loyalty adjustment selalu menambah poin, tidak pernah mengurangi:

1. **BUG-NEW-002** (sudah tercatat) — `replace(/\D/g, '')` di UI menghapus tanda minus
2. **Silent cap di hook** (baru) — `Math.max(0, member.points + points)` diam-diam membatasi ke 0 tanpa error

```ts
// line 103-112 — points selalu positif karena UI strip minus
const newPoints = Math.max(0, member.points + points)  // silent failure jika negatif
// ...
await supabase.from('loyalty_transactions').insert({
  type: 'adjustment',
  points,         // ← selalu positif (minus sudah dihapus di UI)
  description,
})
await supabase.from('loyalty_members').update({ points: newPoints })
```

**Tambahan:** Kolom `loyalty_transactions.points` selalu menyimpan nilai positif, sehingga audit log tidak membedakan "tambah 200 poin" vs "kurang 200 poin". Riwayat transaksi menjadi tidak akurat.

**Fix Lengkap:**
1. Fix UI (BUG-NEW-002): `parseInt(values.points.trim(), 10)` — supports minus
2. Ubah `Math.max(0, ...)` → throw error jika `member.points + points < 0`
3. Simpan `points` apa adanya (positif = tambah, negatif = kurang) di `loyalty_transactions`

---

### BUG-PASS4-004 — useCloseShift: kalkulasi kas tidak atomic (TOCTOU)

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useShifts.ts:74-124` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
`useCloseShift` melakukan 3 query terpisah sebelum menutup shift:
1. Fetch `orders` yang `paid` dalam shift ini
2. Fetch `payments` dari order IDs tersebut
3. Fetch `opening_cash` dari shift
4. Update shift dengan `expected_cash` dan `cash_difference`

Jika ada order baru yang dibayar antara step 1 dan step 4 (misalnya kasir lain menggunakan aplikasi kasir), `expected_cash` akan dihitung berdasarkan data lama — selisih kas (cash_difference) yang tercatat akan salah.

**Fix:** Pindahkan logika kalkulasi `expected_cash` ke DB function/trigger yang berjalan saat shift di-close:
```sql
CREATE OR REPLACE FUNCTION close_shift(shift_id uuid, closing_cash numeric, notes text)
RETURNS void AS $$ ...
```

---

### BUG-PASS4-005 — useSyncItemExtras / useUpdateExtra: data loss jika insert gagal

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useMenuItems.ts:92-96`, `hooks/queries/useExtras.ts:88-95` |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:**  
Dua operasi "delete-then-insert" tanpa transaction:

**`useSyncItemExtras`:**
```ts
// line 92-96 — delete SEMUA, lalu re-insert
await anyTable('menu_item_extras').delete().eq('menu_item_id', itemId)
if (extraIds.length > 0) {
  const { error } = await anyTable('menu_item_extras').insert(rows)
  if (error) throw error  // sudah terlambat — semua extras sudah terhapus
}
```

**`useUpdateExtra`:**
```ts
// line 89-95 — delete options SEMUA, lalu re-insert
await optionsTable().delete().eq('extra_id', id)
if (options.length > 0) {
  const { error: optErr } = await optionsTable().insert(rows)
  if (optErr) throw optErr  // sudah terlambat — semua options sudah terhapus
}
```

**Skenario:** Network timeout saat insert → semua extras/options terhapus permanen untuk item tersebut.

**Fix:** Gunakan Supabase RPC yang wrap operasi ini dalam DB transaction, ATAU:
- Untuk `useSyncItemExtras`: upsert by `(menu_item_id, extra_id)` dan delete hanya yang tidak ada di `extraIds`
- Untuk `useUpdateExtra`: sama, upsert by `(extra_id, name)` dan hapus yang tidak ada

---

## 🟡 Medium

### BUG-PASS4-006 — OwnerDashboard: `now` beku via `useMemo([])`

| Field | Detail |
|-------|--------|
| **File** | `pages/owner/Dashboard.tsx:111` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**
```ts
const now = useMemo(() => new Date(), [])  // frozen sejak mount
```

"Terakhir Diperbarui" di Owner Dashboard selalu menampilkan waktu saat halaman pertama dibuka. Identik dengan BUG-PASS3-005 di Admin Dashboard.

**Fix:** Hapus `useMemo`, atau gunakan `useState` + update saat data refetch.

---

### BUG-PASS4-007 — ShiftList: tombol "Buka Shift" tidak diblok saat shift aktif ada

| Field | Detail |
|-------|--------|
| **File** | `pages/admin/ShiftList.tsx:194` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**  
BUG-NEW-004 (shift overlap) dikonfirmasi di layer UI. Meskipun banner "shift sedang berjalan" tampil, tombol "Buka Shift" tetap aktif dan dapat diklik. Tidak ada validasi di `handleOpenShift` yang mencegah pembukaan shift baru jika `activeShifts.length > 0`.

```ts
// line 132-150 — tidak ada pengecekan activeShifts
async function handleOpenShift() {
  if (!selectedKasirId) { ... }  // hanya validasi ini
  await openShift.mutateAsync(...)  // shift kedua berhasil dibuka
}
```

**Fix:**
```ts
async function handleOpenShift() {
  if (activeShifts.length > 0) {
    toast({ title: 'Tutup shift yang berjalan terlebih dahulu', variant: 'destructive' })
    return
  }
  ...
}
```
Dan disable tombol: `disabled={openShift.isPending || !selectedKasirId || activeShifts.length > 0}`

---

### BUG-PASS4-008 — useStaff: tidak ada filter outlet_id — admin melihat semua staff

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useStaff.ts:7-19` |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:**
```ts
// useStaff() — tidak ada outlet_id filter
const { data, error } = await supabase
  .from('profiles')
  .select('*')
  .in('role', ['admin', 'kasir', 'dapur'])
  .order('full_name')
```

Admin yang login ke outlet A dapat melihat nama, role, dan nomor telepon seluruh staff dari semua outlet. Ini data exposure lintas outlet.

**Catatan:** RLS di Supabase mungkin sudah membatasi ini di level DB, tapi jika RLS belum dikonfigurasi untuk profiles table, ini adalah kebocoran data.

**Fix:** Tambah parameter `outletId` dan filter `.eq('outlet_id', outletId)` untuk role admin. Owner tetap melihat semua staff.

---

## 🟢 Low

### BUG-PASS4-009 — queryClient: refetchOnWindowFocus false + staleTime 5 menit

| Field | Detail |
|-------|--------|
| **File** | `lib/queryClient.ts:6-8` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**
```ts
defaultOptions: {
  queries: {
    staleTime: 1000 * 60 * 5,   // 5 menit
    retry: 2,
    refetchOnWindowFocus: false,  // tidak refresh saat tab aktif kembali
  },
}
```

Kombinasi ini berarti data bisa 5+ menit stale. Admin yang kembali ke tab setelah meeting tidak akan melihat data terbaru. Untuk data kritis seperti stok dan order, ini bisa menyebabkan keputusan berdasarkan data lama.

**Fix:** Pertahankan `staleTime: 5 * 60 * 1000` untuk data tidak kritis, tapi override untuk data kritis:
```ts
// Di hooks spesifik
queryKey: ['orders', outletId],
staleTime: 30_000,   // 30 detik untuk orders
refetchOnWindowFocus: true,
```

---

### BUG-PASS4-010 — DashboardRedirect: kasir/dapur tidak di-redirect ke halaman yang sesuai

| Field | Detail |
|-------|--------|
| **File** | `router/DashboardRedirect.tsx:18-19` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**
```ts
if (profile.role === 'owner') return <Navigate to="/owner/dashboard" replace />
return <Navigate to="/admin/dashboard" replace />  // admin, kasir, dapur → semua ke admin
```

User dengan role `kasir` atau `dapur` yang mengakses `/` akan di-redirect ke `/admin/dashboard`. Halaman ini dilindungi `allowedRoles: ['owner', 'admin']`, sehingga mereka akan mendapat halaman 403. Ini membingungkan — user kasir seharusnya mendapat halaman yang sesuai (atau pesan lebih jelas).

**Dampak:** Role kasir/dapur tidak memiliki destination yang valid di owner-panel, tapi redirect ke 403 bukan penjelasan yang baik.

---

### BUG-PASS4-011 — useSales: `enabled: true` tanpa outletId guard

| Field | Detail |
|-------|--------|
| **File** | `hooks/queries/useSales.ts:10-28` |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:**
```ts
// useDailySales, useTopMenuItems, useProfitLoss, dll:
enabled: true,  // selalu fetch, tanpa cek outletId
// ...
if (outletId) query = query.eq('outlet_id', outletId)
// ↑ jika outletId null → fetch SEMUA outlets tanpa filter
```

Jika dipanggil dari konteks admin (yang seharusnya hanya melihat 1 outlet) dengan `outletId = null`, semua data dari semua outlet akan di-fetch. Owner Dashboard memanggil ini dengan `null` secara sengaja (melihat semua outlet), tapi jika admin page salah memanggil tanpa outletId, data cross-outlet akan tampil.

---

## Temuan Positif Pass 4

| Komponen | Catatan |
|----------|---------|
| ✅ useRealtimeOrders | Channel cleanup benar, filter outlet_id ada |
| ✅ useOrderAuditLog | Read-only, aman |
| ✅ useMenuRecipes | Upsert by composite key, aman |
| ✅ DashboardRedirect | owner/admin redirect benar, null profile guard ada |
| ✅ useDeleteOutlet | Hard delete, tapi sudah ada dialog confirm di UI |
| ✅ queryKey consistency | Semua hooks include outletId dalam queryKey |
| ✅ useActiveShifts | refetchInterval: 30s untuk data kritis |
| ✅ ErrorBoundary | Ada di router level |

---

## Summary — Total Bug Semua Pass

| Pass | Bug |
|------|-----|
| Pass 1 | BUG-OP-001 s/d BUG-OP-007 = **7 bug** |
| Pass 2 | BUG-NEW-001 s/d BUG-NEW-013 = **13 bug** |
| Pass 3 | BUG-SEC-001, BUG-SEC-002, BUG-PASS3-001 s/d BUG-PASS3-012 = **14 bug** |
| Pass 4 | BUG-PASS4-001 s/d BUG-PASS4-011 = **11 bug** |
| **TOTAL** | **45 bug** |

---

## Top Priority Belum Diperbaiki (Global)

| Rank | Bug | Severity | Est. |
|------|-----|----------|------|
| #1 | BUG-NEW-001: Edit outlet hapus semua settings | Critical | 5 menit |
| #2 | BUG-SEC-001: ProtectedRoute bypass jika profile null | Security | 10 menit |
| #3 | BUG-PASS4-001: Voucher code pakai Math.random() | Security | 5 menit |
| #4 | BUG-PASS4-002: Stock adjustment TOCTOU | High | 2 jam (butuh RPC) |
| #5 | BUG-PASS4-003: Loyalty selalu tambah poin | High | 30 menit |
| #6 | BUG-PASS4-005: Delete-then-insert tanpa transaction | High | 1 jam |
| #7 | BUG-NEW-002: Loyalty minus sign stripped | High | 2 menit |
| #8 | BUG-PASS3-002: Header 'Profil' → 403 untuk kasir | High | 5 menit |
| #9 | BUG-PASS3-008: Min password 6 vs 8 | Low | 2 menit |
| #10 | BUG-PASS4-007: Shift overlap bisa terjadi | Medium | 10 menit |

---

*Pass 4 mencakup seluruh 19 file hooks/queries, 2 file lib, 1 file types, 2 file router, dan 2 halaman tersisa. Total audit mencakup 100% dari seluruh codebase owner-panel.*

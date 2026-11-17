# Bug Report Template

> Salin section di bawah dan paste ke [BUG_REPORT.md](./BUG_REPORT.md) (atau buat sub-dokumen baru per modul). Ganti `<...>` dengan nilai sebenarnya.

---

## BUG-<MODUL>-<NNN> — <Judul singkat & spesifik>

**Severity:** BLOCKER / CRITICAL / HIGH / MEDIUM / LOW
**Status:** OPEN / IN PROGRESS / FIXED / WON'T FIX / DUPLICATE
**Reporter:** <nama>
**Tanggal lapor:** YYYY-MM-DD
**Assignee:** <nama dev>
**Affected version / commit:** `<git sha>` atau `v1.0.0`
**Environment:** Local dev / Production / Both
**Browser & OS:** Chrome 124 on macOS / Mobile Chrome Android 13 / etc

---

### Deskripsi

<Apa yang salah, dalam 1-3 kalimat. Hindari jargon. Tulis dari sudut pandang user.>

### Reproduce Steps

1. Login sebagai `<role>` ke `<env>`
2. Buka halaman `<route>`
3. Klik / isi `<...>`
4. ...

### Expected Behavior

<Apa yang seharusnya terjadi.>

### Actual Behavior

<Apa yang sebenarnya terjadi. Lampirkan error message persis kalau ada.>

```
<paste console error / network error / stack trace di sini>
```

### Screenshot / Recording

<Tempel screenshot atau link recording (.mov/.gif). Jika multiple, beri caption.>

### Root Cause (jika sudah diketahui)

<File + baris penyebab. Contoh: `src/hooks/queries/useSales.ts:64` — `.like('pay_date', \`${month}%\`)` gagal karena `pay_date` bertipe `date`.>

### Dampak (Impact)

- **User yang terdampak:** <semua admin / hanya owner / hanya outlet X>
- **Frekuensi:** <selalu / kadang / hanya saat kondisi Y>
- **Workaround:** <ada / tidak — jelaskan>
- **Severity reasoning:** <kenapa rating severity tsb dipilih>

### Fix Suggestion / Action Required

```ts
// before
.like('pay_date', `${month}%`)

// after
.gte('pay_date', monthStart).lte('pay_date', monthEnd)
```

Atau langkah manual jika fix di luar code (mis. migration, reset password, config Supabase).

### Verification Steps (untuk QA setelah fix)

1. Pull commit `<sha fix>`
2. Reload halaman `<route>`
3. Cek: <kondisi yang harus benar>
4. Jalankan automated test: `npm run test -- <spec>`

### Related

- Related bugs: BUG-XXX-001, BUG-YYY-002
- PR fix: #<nomor PR>
- Test case: TC-MODUL-NN
- User story / ticket: <link>

---

## Severity Guide

| Level | Definisi | Contoh | SLA fix |
|---|---|---|---|
| **BLOCKER** | Aplikasi tidak bisa dipakai sama sekali; release ditahan | Login broken, build crash | Same day |
| **CRITICAL** | Fitur utama tidak berfungsi, tidak ada workaround | Tidak bisa simpan menu, dashboard putih | < 1 hari |
| **HIGH** | Fitur penting bug, ada workaround | Filter date salah, export CSV kolom hilang | < 3 hari |
| **MEDIUM** | Fitur sekunder bug, atau UI/UX issue jelas | Tombol tidak responsive, validasi lemah | Sprint berikut |
| **LOW** | Polish, nice-to-have | Spacing kurang rapi, typo | Backlog |

## Status Lifecycle

```
OPEN → IN PROGRESS → FIXED → VERIFIED (QA) → CLOSED
             ↓
        WON'T FIX (with reason)
             ↓
        DUPLICATE (link to original)
```

## Contoh ID Format

| Modul | Prefix |
|---|---|
| Auth | BUG-AUTH-NNN |
| Dashboard | BUG-DASH-NNN |
| Menu | BUG-MENU-NNN |
| Laporan | BUG-LAP-NNN |
| Laporan API | BUG-LAP-API-NNN |
| Orders | BUG-ORD-NNN |
| Stock | BUG-STK-NNN |
| Staff | BUG-STAFF-NNN |
| Settings | BUG-SET-NNN |
| Mobile | BUG-MOB-NNN |
| Cross-cutting (perf, sec) | BUG-XCC-NNN |

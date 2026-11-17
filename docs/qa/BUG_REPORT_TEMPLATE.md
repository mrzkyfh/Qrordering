# Bug Report Template — Owner Panel

---

## [BUG-XXX] Judul Singkat Bug

| Field | Detail |
|-------|--------|
| **ID** | BUG-XXX |
| **Tanggal** | YYYY-MM-DD |
| **Reporter** | Nama QA |
| **Modul** | Nama halaman/fitur |
| **Prioritas** | Critical / High / Medium / Low |
| **Status** | Open / In Progress / Fixed / Closed / Won't Fix |
| **Assignee** | Nama developer |
| **Browser** | Chrome 124 / Safari / Firefox |
| **Environment** | Dev / Staging / Production |

---

### Deskripsi
> Penjelasan singkat tentang masalah yang ditemukan.

---

### Langkah Reproduksi
1. Buka halaman [URL]
2. Klik/isi [field/tombol]
3. Lakukan [aksi]
4. Amati [hasil]

---

### Expected Result
> Apa yang seharusnya terjadi.

---

### Actual Result
> Apa yang sebenarnya terjadi.

---

### Screenshot / Video
> Lampirkan di sini.

---

### Data Test
```
Email: test@example.com
Outlet: Cabang Test
Data input: { field: "nilai" }
```

---

### Catatan Tambahan
> Informasi lain yang relevan, workaround, frekuensi kejadian.

---

---

# Bug Reports Aktif — Owner Panel
**Sesi:** 2026-05-27

---

## [BUG-OP-001] Input negatif pada field qty stok tidak sepenuhnya diblokir

| Field | Detail |
|-------|--------|
| **Modul** | Stock Manager — Adjustment Dialog |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:** Tombol minus keyboard diblokir via `onKeyDown`, namun user masih bisa paste angka negatif dari clipboard.

**Langkah Reproduksi:**
1. Buka /admin/stock → klik Adjustment
2. Copy teks "-5" dari tempat lain
3. Paste ke field qty

**Expected:** Nilai negatif ditolak, field hanya menerima angka positif  
**Actual:** Angka negatif dapat di-input melalui paste

**Fix yang Disarankan:** Tambah validasi di `onChange` handler: `Math.abs(parseFloat(value))` atau gunakan `pattern="[0-9]*"` + validasi Zod `z.number().positive()`.

---

## [BUG-OP-002] Outlet context hilang saat page refresh

| Field | Detail |
|-------|--------|
| **Modul** | Admin Dashboard / Semua halaman admin |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:** `OutletContext` menyimpan `selectedOutletId` hanya di React state (tidak ada localStorage). Saat user refresh halaman, outlet yang dipilih hilang dan user harus memilih ulang.

**Langkah Reproduksi:**
1. Login sebagai admin
2. Pilih outlet dari header
3. Navigasi ke /admin/menu
4. Refresh browser (F5)

**Expected:** Outlet tetap terpilih  
**Actual:** NoOutlet component muncul, harus pilih ulang

**Fix yang Disarankan:** Simpan `selectedOutletId` ke `localStorage` di `OutletContext`.

---

## [BUG-OP-003] Export PDF Reports kosong jika data melebihi 1 halaman

| Field | Detail |
|-------|--------|
| **Modul** | Reports — Export PDF |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:** jsPDF dengan autoTable tidak selalu menangani pagination data yang sangat panjang dengan benar. Jika tabel melebihi 1 halaman PDF, baris terakhir bisa terpotong.

**Langkah Reproduksi:**
1. Buka /admin/reports → Tab Daily Sales
2. Pilih date range 90 hari
3. Klik Export PDF

**Expected:** PDF berisi semua halaman data  
**Actual:** Data baris terakhir terpotong di halaman pertama

**Fix yang Disarankan:** Pastikan `startY` autoTable dihitung ulang per halaman dan `didDrawPage` hook dipakai untuk header berulang.

---

## [BUG-OP-004] Form edit staff — field email tidak disabled secara visual jelas

| Field | Detail |
|-------|--------|
| **Modul** | Owner Staff Manager — Edit Dialog |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:** Saat edit staff, email tidak bisa diubah (tidak ada field email di form edit), namun tidak ada informasi/tooltip yang menjelaskan hal ini kepada user.

**Expected:** Ada label/tooltip "Email tidak dapat diubah"  
**Actual:** Field email tidak tampil tanpa penjelasan

---

## [BUG-OP-005] Promo — end_date bisa diset sebelum start_date

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager — Create/Edit |
| **Prioritas** | High |
| **Status** | Open |

**Deskripsi:** Form promo tidak memvalidasi bahwa `end_date >= start_date`. User bisa menyimpan promo dengan end_date di masa lalu atau sebelum start_date.

**Langkah Reproduksi:**
1. Buka /admin/promos → Tambah Promo
2. Set start_date = 2026-06-01, end_date = 2026-05-01
3. Klik Simpan

**Expected:** Error "Tanggal akhir harus setelah tanggal mulai"  
**Actual:** Promo tersimpan dengan date yang tidak valid

**Fix yang Disarankan:** Tambah validasi Zod: `.refine(data => !data.end_date || !data.start_date || data.end_date >= data.start_date, { message: "Tanggal akhir harus setelah tanggal mulai" })`

---

## [BUG-OP-006] Finance Report — data tidak di-refresh saat ganti outlet

| Field | Detail |
|-------|--------|
| **Modul** | Finance Report (Owner) |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:** Saat owner mengganti outlet di dropdown finance report, data terkadang tidak ter-refresh sampai user mengubah bulan juga.

**Langkah Reproduksi:**
1. Buka /owner/finance
2. Pilih outlet A — data outlet A tampil
3. Ganti ke outlet B

**Expected:** Data segera berubah ke outlet B  
**Actual:** Data outlet A masih tampil sebentar (cache stale)

**Fix yang Disarankan:** Pastikan `queryKey` di useQuery menyertakan `selectedOutletId` sehingga query baru di-trigger saat outlet berubah.

---

## [BUG-OP-007] Loyalty — adjust poin tidak memvalidasi bahwa hasil akhir tidak negatif

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager — Adjust Points |
| **Prioritas** | Medium |
| **Status** | Open |

**Deskripsi:** User bisa memasukkan poin negatif yang melebihi total poin member, menghasilkan poin negatif.

**Contoh:** Member punya 100 poin, admin adjust -500 → member jadi -400 poin.

**Expected:** Error "Poin tidak cukup" atau total minimum adalah 0  
**Actual:** Member bisa memiliki poin negatif

**Fix yang Disarankan:** Validasi di backend: `total_points + adjustment >= 0`, kembalikan error 400 jika tidak valid.

---

---

# Bug Reports — Second Pass (2026-05-27)

---

## [BUG-NEW-001] Edit Outlet di BranchMonitoring menghapus semua settings

| Field | Detail |
|-------|--------|
| **Modul** | Branch Monitoring — Edit Outlet |
| **Prioritas** | **Critical** |
| **Status** | Open |
| **File** | `pages/owner/BranchMonitoring.tsx:113-125` |

**Deskripsi:** `onSubmit` di `OutletFormDialog` membuat object `settings` baru tanpa spread settings lama. Setiap edit outlet menghapus `payment_methods`, `taxes` array, `rounding`, dan semua settings lainnya.

**Langkah Reproduksi:**
1. Aktifkan metode pembayaran QRIS di PaymentManager
2. Edit nama outlet di BranchMonitoring → Simpan
3. Cek PaymentManager → QRIS hilang

**Expected:** Settings yang tidak diubah tetap terjaga  
**Actual:** Semua settings direset ke default

**Fix:** Tambah `...editData?.settings` di dalam object `settings` payload.

---

## [BUG-NEW-002] Loyalty: Pengurangan poin tidak berfungsi — minus sign terhapus

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager — Adjust Points |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `pages/admin/LoyaltyManager.tsx:145` |

**Deskripsi:** `values.points.replace(/\D/g, '')` menghapus tanda minus. Input `-200` diproses sebagai `200`. UI meminta input minus tapi tidak pernah berfungsi.

**Expected:** Input -200 mengurangi poin member  
**Actual:** Input -200 justru menambah 200 poin

**Fix:** `parseInt(values.points.trim(), 10)` — `parseInt` mendukung tanda minus secara native.

---

## [BUG-NEW-003] OrderList: Alasan void tidak tersimpan ke database

| Field | Detail |
|-------|--------|
| **Modul** | Order List — Void Order |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `pages/admin/OrderList.tsx` |

**Deskripsi:** Dialog void mengumpulkan alasan tapi `voidMutation.mutationFn` tidak menyertakan `void_reason` dalam Supabase update. Kolom selalu null.

**Expected:** `void_reason` tersimpan di database  
**Actual:** `void_reason` selalu null

---

## [BUG-NEW-004] ShiftList: Tidak ada proteksi terhadap shift yang overlap

| Field | Detail |
|-------|--------|
| **Modul** | Shift Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `pages/admin/ShiftList.tsx` |

**Deskripsi:** Tidak ada pengecekan shift "open" yang sudah ada sebelum membuka shift baru. Dua shift bisa aktif bersamaan untuk outlet yang sama.

**Expected:** Error jika shift masih terbuka  
**Actual:** Shift baru bisa dibuka, menyebabkan kalkulasi kas tidak akurat

---

## [BUG-NEW-005] PaymentManager: Semua metode bisa dinonaktifkan

| Field | Detail |
|-------|--------|
| **Modul** | Payment Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/PaymentManager.tsx:40-48` |

**Deskripsi:** Tidak ada validasi minimum 1 metode aktif di `handleSave`. `payment_methods: []` bisa tersimpan.

**Fix:** Cek `enabled.length === 0` sebelum save, tampilkan error toast.

---

## [BUG-NEW-006] BranchMonitoring: `todayRange` beku sejak modul di-load

| Field | Detail |
|-------|--------|
| **Modul** | Branch Monitoring |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/owner/BranchMonitoring.tsx:32` |

**Deskripsi:** `const todayRange = { from: startOfDay(new Date()), to: endOfDay(new Date()) }` di level modul. Jika app terbuka melewati tengah malam, omzet "hari ini" menampilkan data kemarin.

---

## [BUG-NEW-007] TableManager: Tidak ada tombol hapus meja

| Field | Detail |
|-------|--------|
| **Modul** | Table Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/TableManager.tsx` |

**Deskripsi:** Tidak ada delete action di mana pun. Meja yang salah input tidak bisa dihapus dari UI.

---

## [BUG-NEW-008] PromoManager: Promo expired tampil sebagai "Aktif"

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/PromoManager.tsx:130` |

**Deskripsi:** Badge status hanya mengecek `is_active` dari DB, tidak membandingkan `end_date` dengan tanggal hari ini. Promo yang sudah kadaluarsa tetap tampil "Aktif".

---

## [BUG-NEW-009] Reports: Variabel `today` tidak realtime

| Field | Detail |
|-------|--------|
| **Modul** | Reports |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/Reports.tsx` |

**Deskripsi:** `today` dihitung saat komponen mount. Jika halaman dibuka lama, filter "hari ini" menggunakan tanggal lama.

---

## [BUG-NEW-010] TableManager: Nomor meja duplikat tidak divalidasi di client

| Field | Detail |
|-------|--------|
| **Modul** | Table Manager |
| **Prioritas** | Low |
| **Status** | Open |

---

## [BUG-NEW-011] ChargesSettings: Service charge > 100% bisa tersimpan

| Field | Detail |
|-------|--------|
| **Modul** | Charges Settings |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:** `max={100}` pada HTML input tidak berlaku untuk button-triggered save. Value > 100 bisa tersimpan.

---

## [BUG-NEW-012] ExpenseManager: Tanggal pengeluaran bisa masa depan

| Field | Detail |
|-------|--------|
| **Modul** | Expense Manager |
| **Prioritas** | Low |
| **Status** | Open |

---

## [BUG-NEW-013] PromoManager: Tipe bundling/BOGO adalah dead feature

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **Prioritas** | Low |
| **Status** | Open |

**Deskripsi:** Tipe `bundling` dan `bogo` tidak memiliki UI untuk menentukan item yang terlibat. Promo tipe ini tersimpan tapi tidak berfungsi secara bisnis.

---

---

# Bug Reports — Fourth Pass (2026-05-27)

---

## [BUG-PASS4-001] generateCode: Math.random() untuk kode voucher — tidak aman secara kriptografi

| Field | Detail |
|-------|--------|
| **Modul** | Voucher Manager |
| **Prioritas** | **Security / High** |
| **Status** | Open |
| **File** | `hooks/queries/useVouchers.ts:26-28` |

**Deskripsi:** `Math.random()` digunakan untuk generate kode voucher. Tidak kriptografis — kode bisa diprediksi.

**Fix:** Gunakan `crypto.getRandomValues(new Uint8Array(length))` sebagai sumber entropi.

---

## [BUG-PASS4-002] useStockAdjustment: TOCTOU race condition pada qty_before

| Field | Detail |
|-------|--------|
| **Modul** | Stock Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `hooks/queries/useIngredients.ts:171-196` |

**Deskripsi:** `qty_before` difetch terpisah sebelum insert `stock_transactions`. Concurrent adjustment menghasilkan audit log yang tidak akurat — `qty_before` dan `qty_after` mencerminkan data stale.

**Fix:** Pindahkan ke DB RPC function yang melakukan read + insert dalam satu transaction atomik.

---

## [BUG-PASS4-003] useAdjustPoints: poin selalu bertambah, audit log tidak akurat

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `hooks/queries/useLoyalty.ts:103-112` |

**Deskripsi:** Gabungan BUG-NEW-002 (UI strip minus) dan `Math.max(0, ...)` di hook yang silent fail. Poin tidak pernah berkurang. Kolom `loyalty_transactions.points` selalu positif, riwayat transaksi tidak akurat.

**Fix:** (1) Fix UI strip minus, (2) throw error jika result < 0, (3) simpan nilai asli (negatif) di transactions.

---

## [BUG-PASS4-004] useCloseShift: kalkulasi kas tidak atomic

| Field | Detail |
|-------|--------|
| **Modul** | Shift Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `hooks/queries/useShifts.ts:74-124` |

**Deskripsi:** Tiga query sequential (orders → payments → opening_cash) sebelum update shift. Pembayaran yang terjadi di antara query menyebabkan `expected_cash` yang salah.

**Fix:** Pindahkan kalkulasi `expected_cash` ke DB function/trigger saat shift di-close.

---

## [BUG-PASS4-005] useSyncItemExtras / useUpdateExtra: data loss jika insert gagal setelah delete

| Field | Detail |
|-------|--------|
| **Modul** | Menu Manager / Extra Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `hooks/queries/useMenuItems.ts:92-96`, `hooks/queries/useExtras.ts:88-95` |

**Deskripsi:** Pola `delete().then(insert())` tanpa transaction. Jika insert gagal (network timeout, dll), semua extras/options untuk item tersebut terhapus permanen.

**Fix:** Gunakan upsert + selective delete, atau wrap dalam DB transaction via RPC.

---

## [BUG-PASS4-006] OwnerDashboard: `now` beku via `useMemo([])`

| Field | Detail |
|-------|--------|
| **Modul** | Owner Dashboard |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/owner/Dashboard.tsx:111` |

**Deskripsi:** `const now = useMemo(() => new Date(), [])` — "Terakhir Diperbarui" frozen sejak mount. Sama dengan BUG-PASS3-005 di Admin Dashboard.

**Fix:** Hapus `useMemo`, atau gunakan state yang di-update saat data refetch.

---

## [BUG-PASS4-007] ShiftList: tombol "Buka Shift" tidak diblokir saat shift aktif ada

| Field | Detail |
|-------|--------|
| **Modul** | Shift Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/ShiftList.tsx:132-150` |

**Deskripsi:** `handleOpenShift` tidak mengecek `activeShifts.length`. Banner "shift berjalan" tampil tapi tombol "Buka Shift" tetap bisa diklik — dua shift bisa aktif bersamaan (BUG-NEW-004 dikonfirmasi di level UI).

**Fix:** Guard di `handleOpenShift`: `if (activeShifts.length > 0) { toast error; return }`.

---

## [BUG-PASS4-008] useStaff: tidak ada filter outlet_id — admin melihat semua staff

| Field | Detail |
|-------|--------|
| **Modul** | Staff Manager / Owner Dashboard |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `hooks/queries/useStaff.ts:7-19` |

**Deskripsi:** `useStaff()` fetch semua profiles dengan role admin/kasir/dapur tanpa filter `outlet_id`. Admin outlet A bisa melihat data staff dari outlet B (nama, role, phone).

**Fix:** Tambah parameter `outletId` dan filter `.eq('outlet_id', outletId)` untuk admin. Owner tetap tanpa filter.

---

## [BUG-PASS4-009] queryClient: staleTime 5 menit + refetchOnWindowFocus false

| Field | Detail |
|-------|--------|
| **Modul** | Global Query Config |
| **Prioritas** | Low |
| **Status** | Open |
| **File** | `lib/queryClient.ts:6-8` |

**Deskripsi:** Default global: `staleTime: 5 menit` + `refetchOnWindowFocus: false`. Data order dan stok bisa 5+ menit stale saat admin kembali ke tab.

**Fix:** Override di hooks kritis (orders, shifts) dengan `staleTime: 30_000` dan `refetchOnWindowFocus: true`.

---

## [BUG-PASS4-010] DashboardRedirect: kasir/dapur di-redirect ke halaman yang membutuhkan role admin

| Field | Detail |
|-------|--------|
| **Modul** | Router |
| **Prioritas** | Low |
| **Status** | Open |
| **File** | `router/DashboardRedirect.tsx:18-19` |

**Deskripsi:** Role `kasir` dan `dapur` di-redirect ke `/admin/dashboard` yang `allowedRoles: ['owner', 'admin']` — mereka mendapat halaman 403 yang membingungkan.

---

## [BUG-PASS4-011] useSales: `enabled: true` tanpa outletId guard

| Field | Detail |
|-------|--------|
| **Modul** | Reports / Dashboard |
| **Prioritas** | Low |
| **Status** | Open |
| **File** | `hooks/queries/useSales.ts:10-28` |

**Deskripsi:** Semua hooks di useSales menggunakan `enabled: true` tanpa cek `outletId`. Jika admin page memanggil dengan `outletId = null`, semua data lintas-outlet akan di-fetch (tidak ada RLS filter client-side).

---

---

# Bug Reports — Fifth Pass (2026-05-27)

---

## [BUG-PASS5-001] Reports: CSV Formula Injection pada semua export

| Field | Detail |
|-------|--------|
| **Modul** | Reports / Stock Report |
| **Prioritas** | Security / Medium |
| **Status** | Open |
| **File** | `pages/admin/Reports.tsx:66-82`, `pages/admin/StockReport.tsx:85-97` |

**Deskripsi:** Nilai yang dimulai `=`, `+`, `-`, `@` tidak di-sanitasi sebelum masuk ke file CSV. Excel akan mengeksekusi nilai tersebut sebagai formula.

**Fix:** Prefix nilai dengan apostrofe `'` jika dimulai karakter formula.

---

## [BUG-PASS5-002] Reports: exportExcel tanpa HTML escaping — data injection

| Field | Detail |
|-------|--------|
| **Modul** | Reports |
| **Prioritas** | Security / Low |
| **Status** | Open |
| **File** | `pages/admin/Reports.tsx:87-98` |

**Deskripsi:** Data user dimasukkan langsung ke template HTML `<td>${s}</td>` tanpa escaping. Nama yang mengandung `<`, `>`, `&` merusak struktur HTML Excel export.

**Fix:** Escape karakter HTML sebelum inject ke template.

---

## [BUG-PASS5-003] PromoManager: nilai persentase > 100% tidak divalidasi

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `pages/admin/PromoManager.tsx:28-38` |

**Deskripsi:** Schema tidak memvalidasi nilai persentase maks 100. Admin bisa menyimpan promo 999% yang menyebabkan `total_amount` order menjadi negatif.

**Fix:** Validasi `value <= 100` di `onSubmit` saat `type === 'percentage'`.

---

## [BUG-PASS5-004] OrderList: voidMutation tidak menyimpan void_reason (konfirmasi BUG-NEW-003)

| Field | Detail |
|-------|--------|
| **Modul** | Order List |
| **Prioritas** | High |
| **Status** | Open |
| **File** | `pages/admin/OrderList.tsx:69-76` |

**Deskripsi:** `{ id }: { id: string; reason: string }` — `reason` didesktruktuk tapi tidak dipakai dalam `.update({ status: 'void' })`.

**Fix:** Tambahkan `void_reason: reason || null` ke dalam object update.

---

## [BUG-PASS5-005] MenuManager: image lama tidak dihapus dari Storage saat diganti

| Field | Detail |
|-------|--------|
| **Modul** | Menu Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/MenuManager.tsx:87-89` |

**Deskripsi:** `handleRemoveImage()` hanya reset state lokal, tidak memanggil Storage delete. File lama terus menumpuk di bucket `menu-images`.

**Fix:** Extract path dari URL dan hapus dari Storage sebelum reset state.

---

## [BUG-PASS5-006] StockReport: exportCSV tanpa quote escaping untuk koma dalam nama

| Field | Detail |
|-------|--------|
| **Modul** | Stock Report |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/StockReport.tsx:85-97` |

**Deskripsi:** Join langsung `[...].join(',')` tanpa quoting. Nama bahan yang mengandung koma merusak format CSV.

**Fix:** Tambahkan quoting untuk nilai yang mengandung koma atau tanda kutip.

---

## [BUG-PASS5-007] LoyaltyManager: detailMember stale setelah adjust poin

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager |
| **Prioritas** | Medium |
| **Status** | Open |
| **File** | `pages/admin/LoyaltyManager.tsx:143-157` |

**Deskripsi:** Setelah adjustment berhasil, detail sheet masih menampilkan poin lama. `detailMember` state tidak diperbarui setelah mutation.

**Fix:** Set `detailMember(null)` atau invalidate query setelah adjustment sukses.

---

## [BUG-PASS5-008] PromoManager: edit promo selalu reset is_active ke true

| Field | Detail |
|-------|--------|
| **Modul** | Promo Manager |
| **Prioritas** | Low |
| **Status** | Open |
| **File** | `pages/admin/PromoManager.tsx:97` |

**Deskripsi:** Payload selalu `is_active: true`. Promo yang sudah dinonaktifkan akan aktif kembali setelah di-edit.

**Fix:** Gunakan `is_active: editPromo.is_active` saat mode edit.

---

## [BUG-PASS5-009] LoyaltyManager: phone tidak divalidasi format

| Field | Detail |
|-------|--------|
| **Modul** | Loyalty Manager |
| **Prioritas** | Low |
| **Status** | Open |
| **File** | `pages/admin/LoyaltyManager.tsx:48-52` |

**Deskripsi:** `z.string().min(8)` — "aaaaaaaa" lolos validasi. Tidak ada validasi format nomor HP.

**Fix:** Tambah regex: `.regex(/^\+?[\d\s-]{8,}$/, 'Format nomor HP tidak valid')`

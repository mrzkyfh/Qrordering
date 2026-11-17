# Roadmap Fitur Lanjutan (menuju paritas Majoo) — Time420s

**Tanggal:** 2026-07-07
**Status:** SPEC — dokumentasi sebelum eksekusi.
**Scope:** 5 fitur disepakati + analisis gap per-role. (Hutang/piutang dikecualikan atas permintaan.)

---

## Bagian A — Spesifikasi 5 Fitur

Urutan eksekusi: **Stok Opname → Waste → Bundling → Absensi+Komisi → CRM.**

### 1. Stok Opname (audit stok fisik)
**Tujuan:** hitung stok fisik vs sistem, catat selisih, sesuaikan otomatis. Cegah kebocoran.
**Data:**
- `stock_opnames` (id, outlet_id, note, status `draft|final`, created_by, created_at, finalized_at)
- `stock_opname_items` (opname_id, ingredient_id, system_qty, physical_qty, diff, note)
**Logic:** buat opname → snapshot `system_qty` tiap bahan → isi `physical_qty` → **finalize** → tiap `diff ≠ 0` buat `stock_transactions` type `adjustment` (qty = diff) → stok sistem = fisik. RPC `finalize_stock_opname(id)` (atomic, guard sekali final).
**UI:** owner-panel `StockOpname.tsx` (buat → isi tabel bahan → finalisasi + ringkasan selisih). Mobile: opsional (owner/admin).
**Fase:** 1 migrasi + 1 RPC + 1 halaman web. Risiko rendah (adjustment memakai jalur stok yang sudah ada).

### 2. Waste / Spoilage (bahan terbuang)
**Kondisi:** tipe `waste` SUDAH ada di `stock_transaction_type` + form adjustment. Yang kurang: alur khusus + **laporan waste** + kategori alasan.
**Data:** reuse `stock_transactions` (type `waste`). Tambah kolom opsional `reason` (text) atau enum (`expired|rusak|tumpah|lain`).
**Logic:** catat waste (bahan, qty, alasan) → `stock_transactions` type `waste` → stok turun (trigger sudah ada). HPP kerugian = qty × cost_per_unit.
**UI:** owner-panel StockManager → tombol "Catat Waste" (bahan + qty + alasan) + laporan waste (v_waste per periode). Mobile: opsional.
**Fase:** kecil (reuse jalur stok). Fokus: UI catat + view laporan waste.

### 3. Paket / Bundling Produk (combo)
**Tujuan:** 1 item jual = kombinasi beberapa menu (mis. "Paket Kopi + Roti"). Harga paket sendiri. Stok potong komponen.
**Data:**
- `menu_items.is_bundle BOOLEAN` (atau kolom `kind`)
- `bundle_items` (bundle_id → menu_items.id, component_id → menu_items.id, qty)
**Logic:** jual bundle → potong stok tiap komponen (via resep gabungan komponen). HPP bundle = Σ HPP komponen. Harga = harga bundle (bisa < jumlah komponen = diskon paket).
**UI:** owner-panel MenuManager → "Buat Paket" (pilih komponen + qty + harga). POS → bundle tampil sebagai 1 item; saat bayar, stok komponen terpotong.
**Fase:** sedang — sentuh skema menu + alur potong stok (deduct_stock_for_order harus telusuri bundle → komponen → resep).

### 4. Absensi + Komisi Karyawan
**Absensi (jam kerja):**
- Data: `attendances` (id, outlet_id, staff_id, clock_in, clock_out, note). Terpisah dari `shifts` (shift = kas; absensi = jam kerja).
- UI: tombol "Absen Masuk/Pulang" (mobile, saat clock-in staf) + laporan jam kerja per staf (web).
**Komisi:**
- Kondisi: report punya **stub** `commission: 0.0` (`kasir_report_datasource.dart:85`) — tinggal diisi.
- Data: `commission_rules` (outlet_id, role|staff_id, type `percent|per_item`, value) + hitung dari penjualan yang di-handle staf (`orders.created_by`).
- UI: owner-panel atur aturan komisi + laporan komisi per staf.
**Fase:** 2 sub-fitur. Absensi dulu (bounded), lalu komisi (isi stub + rule).

### 5. CRM Pelanggan
**Kondisi:** ada `loyalty_members` (phone, name, points, tier) + lookup by HP. Kurang: **database pelanggan + riwayat kunjungan**.
**Data:** extend `loyalty_members` (alamat, birthday, note) — jangan buat tabel baru. Riwayat = `orders WHERE loyalty_member_id = x`.
**UI:** owner-panel `CustomerManager.tsx` (daftar pelanggan + detail + histori order + total belanja + poin). Mobile: lookup sudah ada.
**Fase:** kecil-sedang (reuse loyalty). Mayoritas UI web.

---

## Bagian B — Gap Fitur per Role (vs Majoo)

Konteks: mobile = POS murni (semua role); manajemen lewat owner-panel web.

### Owner (rank 4 — semua cabang)
| Punya | Kurang vs Majoo |
|-------|-----------------|
| Owner-panel: dashboard multi-outlet, laporan, staf, monitor cabang, log error | **Akuntansi lengkap** (jurnal/buku besar/neraca/arus kas) · **Payroll approval** · **Stok opname oversight** · **Integrasi marketplace** (GoFood/Grab/Shopee) · **Franchise mgmt** · **Konsolidasi lintas-outlet lanjut** |

### Admin (rank 3 — kepala 1 cabang)
| Punya | Kurang vs Majoo |
|-------|-----------------|
| Kelola menu/kategori/stok/promo/meja/staf cabang, laporan cabang | **Stok opname** · **PO lengkap** (approval + terima barang) · **Transfer stok antar outlet** · **Payroll cabang** · **Absensi karyawan** |

### Manajer (rank 2 — supervisor)
| Punya | Kurang vs Majoo |
|-------|-----------------|
| Approve refund/void via PIN, akses laporan (web bila diberi kredensial) | **Approve diskon/harga** (batas otorisasi) · **Monitor absensi/shift tim** · **Approve stok opname/waste** · **Target & insentif tim** |

### Kasir (rank 1 — operator)
| Punya | Kurang vs Majoo |
|-------|-----------------|
| POS, split/diskon, shift + kas masuk/keluar, laporan kasir (buka-tutup + kas), self-order | **Absensi (jam kerja masuk/pulang)** · **Lihat komisi sendiri** · **Reservasi meja** · **Held order** (draft sudah ada sebagian) · **Catat waste cepat** |

---

## Prioritas eksekusi (disepakati)
1. **Stok Opname** — nilai tinggi, risiko rendah, nyambung ke stok.
2. **Waste** — kecil, reuse tipe `waste`.
3. **Bundling** — sedang, sentuh menu + potong stok.
4. **Absensi + Komisi** — komisi tinggal isi stub.
5. **CRM** — reuse loyalty.

**Catatan:** tiap fitur = migrasi + (opsional) UI web/mobile + verifikasi (analyze/test/build). Dikerjakan satu per satu, staging dulu untuk yang sentuh stok/uang.

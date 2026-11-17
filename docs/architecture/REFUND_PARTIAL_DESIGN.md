# Desain: Refund Sebagian / Per-Item (NEW-2)
**Tanggal:** 2026-07-05
**Status:** RANCANGAN (belum ada kode) — perlu persetujuan semantik sebelum implementasi

---

## 1. Masalah
Saat ini refund = **seluruh order** (status → `cancelled`, keluar dari penjualan). Tak bisa refund 1 item dari banyak. Realita F&B: 1 dari 5 item salah/batal → sekarang harus refund semua lalu input ulang.

## 2. Kenapa ini proyek multi-surface (bukan fix kecil)
Angka "penjualan" tersebar & hampir semua difilter `status = 'paid'`:

| Surface | Sumber angka |
|---------|--------------|
| `v_payment_summary` (003) | SUM(payments.amount) |
| `v_shift_summary` (044) | SUM(payments.amount) per metode |
| `category_sales_view` (015) | SUM(order_items.subtotal) WHERE paid |
| `sales_breakdown_views` (031) | order_items / orders |
| `order_hpp_view` (042) | order_items |
| `sales_daily_summary` (084) | orders + payments |
| owner-panel `useSales`, `useShifts`, `useOrderStatusReport` | view di atas |
| mobile `kasir_report_datasource`, `orders_datasource.fetchSales`, `shift_datasource` | orders/payments |

Refund parsial = **kas keluar** setelah order tetap `paid` → tiap surface harus mengurangi refund, kalau tidak **penjualan overstate**. Inilah ripple-nya.

---

## 3. Keputusan Semantik (rekomendasi — perlu konfirmasi)
| # | Pertanyaan | Rekomendasi |
|---|-----------|-------------|
| S1 | Status order setelah refund parsial? | Tetap **`paid`** (order tetap sah, sebagian dikembalikan). |
| S2 | Stok dikembalikan? | **TIDAK** (konsisten dgn aturan "bahan terpakai tak kembali"). |
| S3 | Perlu otorisasi PIN? | **Ya** — reuse `_find_approver` (sama seperti refund penuh/void). |
| S4 | Boleh refund > qty terjual? | **Tidak** — dibatasi `refunded_qty`. |
| S5 | Refund uang tunai/non-tunai? | Catat `method` (default ikut pembayaran asli); untuk laporan kas. |
| S6 | Order sudah refund penuh (cancelled) → parsial? | **Tidak** — hanya order `paid`. |

---

## 4. Data Model
```sql
-- Jejak refund (audit + sumber pengurang laporan)
CREATE TABLE refunds (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  outlet_id   UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  method      payment_method,          -- kas keluar via metode apa
  reason      TEXT,
  refunded_by UUID REFERENCES profiles(id),
  approved_by UUID REFERENCES profiles(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE refund_items (
  refund_id     UUID NOT NULL REFERENCES refunds(id) ON DELETE CASCADE,
  order_item_id UUID NOT NULL REFERENCES order_items(id),
  qty           INTEGER NOT NULL CHECK (qty > 0),
  amount        NUMERIC(12,2) NOT NULL
);
-- Batas anti over-refund
ALTER TABLE order_items ADD COLUMN refunded_qty INTEGER NOT NULL DEFAULT 0;
```

## 5. RPC
```sql
refund_order_items(p_order_id UUID, p_items JSONB, p_reason TEXT,
                   p_approver_id UUID, p_approver_pin TEXT) RETURNS JSONB
-- p_items: [{ "order_item_id": "...", "qty": 2 }, ...]
-- 1. Validasi: order paid, outlet cocok, approver valid (_find_approver).
-- 2. Tiap item: refunded_qty + qty <= quantity; hitung amount = unit_price*qty.
-- 3. Insert refunds + refund_items; increment order_items.refunded_qty.
-- 4. TIDAK ubah status, TIDAK restore stok.
-- 5. Return { refund_id, total_amount }.
```

## 6. Reporting Impact Matrix (WAJIB, ini inti pekerjaan)
| Surface | Perubahan |
|---------|-----------|
| `v_payment_summary` | net = SUM(payments) − SUM(refunds.amount) |
| `v_shift_summary` | `cash_received` −= refunds(method=cash); non-cash serupa |
| `category_sales_view` | qty & revenue −= refund_items (per kategori) |
| `sales_breakdown_views` | idem (per item/kategori) |
| `sales_daily_summary` (rollup) | `net` & `by_payment` kurangi refunds; tambah kolom `refunds` |
| `order_hpp_view` | opsional: HPP tak berubah (bahan tetap terpakai), tapi revenue net turun → margin |
| owner-panel `RefundReport` | tampilkan refund parsial (bukan hanya cancelled) |
| owner-panel `useSales/useShifts` | otomatis ikut bila view diperbarui |
| mobile report datasources | verifikasi ikut view / sesuaikan query |

## 7. Mobile UI
- Di detail order **`paid`**: tombol **"Refund Item"** → sheet pilih item + qty (dibatasi sisa `quantity − refunded_qty`) → input alasan → **PIN approver** → panggil RPC.
- Tampilkan badge "sebagian direfund" + jumlah pada order yang punya refund.

## 8. Urutan Rollout (fase — turunkan risiko)
1. **Fase 1 (data & aksi):** migrasi tabel + RPC + UI mobile refund item. Refund tercatat & bisa dilakukan. **Laporan belum net** (refund tampil terpisah di RefundReport).
2. **Fase 2 (laporan net):** perbarui view satu per satu (payment_summary → shift_summary → category → breakdown → daily_summary), verifikasi tiap angka di staging.
3. **Fase 3:** rollup & arsip (084/086) memasukkan refund.

## 9. Test Plan
- RPC: over-refund ditolak; approver salah ditolak; amount = Σ(unit_price×qty).
- View: order 100k, refund 30k → payment_summary net 70k, shift cash net, category revenue −item.
- Idempotensi: refund 2× item sama tak melebihi qty.
- Stok: tidak berubah setelah refund.

## 10. Risiko & Rekomendasi
- **Risiko utama:** view yang terlewat → penjualan overstate diam-diam. Mitigasi: matriks §6 sebagai checklist + verifikasi angka staging per view.
- **Rekomendasi:** kerjakan **Fase 1 dulu** (nilai langsung: bisa refund item + audit), lalu Fase 2 dengan verifikasi ketat per view. Jangan gabung semua sekaligus.

---
**Perlu keputusan Anda:** konfirmasi semantik §3 (khususnya S1 status tetap paid, S3 wajib PIN). Setelah itu Fase 1 bisa dieksekusi.

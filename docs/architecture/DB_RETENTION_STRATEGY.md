# Strategi Memperpanjang Umur Database (Supabase Free 500 MB)
**Tanggal:** 2026-07-05
**Peran:** DBA
**Status:** RANCANGAN (belum diterapkan — perlu persetujuan sebelum tulis migrasi)

---

## Tujuan
Ubah pertumbuhan DB dari **tak terbatas (selalu naik)** → **steady-state (mendatar)**, sehingga free plan 500 MB bertahan **3–5× lebih lama**, idealnya tak pernah penuh untuk 1 outlet.

## Prinsip: 3-Tier Data Lifecycle
```
HOT  (raw, ≤ 12–18 bln)   → dipakai transaksi & laporan harian → tetap di DB
WARM (rollup harian)      → ringkasan untuk laporan historis   → tabel kecil di DB
COLD (> 12–18 bln)        → diekspor ke Storage/CSV lalu DIHAPUS dari DB
```
Kunci: **bikin rollup dulu**, baru boleh hapus raw — supaya laporan historis tidak hilang.

---

## Kondisi Saat Ini (hasil audit)
- ❌ Tidak ada `pg_cron` → tak ada retensi otomatis
- ❌ Tidak ada `MATERIALIZED VIEW`/rollup → semua laporan baca **raw live** (jadi raw tak bisa asal dihapus)
- ❌ `order_audit_log` append-only, tak pernah dipangkas → penyumbang pertumbuhan terbesar
- ❌ Tak ada tuning `fillfactor`/autovacuum → `orders` (sering di-UPDATE) rawan bloat
- ✅ Sudah ada soft-delete/arsip untuk master data (menu/bahan) — bukan volume transaksi
- ✅ `order_audit_log` hanya dibaca per-order (trail 1 order), **bukan** dipakai laporan agregat → aman dipangkas

---

## Strategi Berlapis (urut prioritas: impact ÷ risiko)

### ⭐ Strategi 0 — Ukur Dulu (WAJIB, tanpa migrasi)
Jalankan di SQL Editor untuk baseline & laju pertumbuhan nyata:
```sql
-- Ukuran total DB
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;

-- Ukuran per tabel (data + index + toast), terbesar dulu
SELECT relname AS tabel,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid))       AS data,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) AS index_toast
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20;

-- Bloat cepat: rasio dead tuple
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup*100.0/NULLIF(n_live_tup+n_dead_tup,0),1) AS dead_pct
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 15;
```
→ Kalibrasi semua asumsi ke data aktual sebelum optimasi.

---

### ⭐ Strategi 1 — Pangkas `order_audit_log` (BESAR, AMAN, LAKUKAN PERTAMA)
Log ini ~3 baris/order & tak pernah menyusut. Simpan **90 hari**, sisanya hapus — **hanya** untuk order yang sudah selesai (jaga trail order yang masih terbuka berapapun umurnya).
```sql
DELETE FROM order_audit_log al
USING orders o
WHERE al.order_id = o.id
  AND al.created_at < now() - interval '90 days'
  AND o.status IN ('paid','void','cancelled');   -- jangan sentuh order aktif
```
**Dampak:** −25–30% laju pertumbuhan. **Risiko:** rendah (trail order lama, non-finansial).

---

### ⭐ Strategi 2 — Bikin Rollup Harian (fondasi untuk hapus raw)
Tabel ringkasan 1 baris/outlet/hari — laporan historis baca dari sini (kecil & cepat), bukan dari jutaan baris raw.
```sql
CREATE TABLE sales_daily_summary (
  outlet_id     UUID NOT NULL,
  sales_date    DATE NOT NULL,
  order_count   INT  NOT NULL DEFAULT 0,
  gross         NUMERIC(14,2) NOT NULL DEFAULT 0,
  discount      NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax           NUMERIC(14,2) NOT NULL DEFAULT 0,
  service       NUMERIC(14,2) NOT NULL DEFAULT 0,
  net           NUMERIC(14,2) NOT NULL DEFAULT 0,
  by_payment    JSONB,   -- {cash: x, qris: y, ...}
  by_category   JSONB,   -- {kopi: x, makanan: y, ...}
  PRIMARY KEY (outlet_id, sales_date)
);
```
Isi via job harian (upsert hari kemarin). Arahkan laporan periode > 60 hari ke tabel ini; raw hanya untuk data terbaru.
**Dampak:** membuka jalan menghapus raw lama tanpa kehilangan angka laporan. **Risiko:** sedang (perlu ubah query laporan).

---

### ⭐ Strategi 3 — Arsip Cold Data (ekspor lalu hapus)
Order (+ items, options, payments) berstatus final & umur **> 12–18 bln**: ekspor ke **Storage bucket (kuota 1 GB terpisah)** atau CSV, lalu hapus dari DB. Rollup (Strategi 2) menjaga laporan tetap utuh.
```sql
-- Sketsa: setelah export sukses
WITH cold AS (
  SELECT id FROM orders
  WHERE created_at < now() - interval '18 months'
    AND status IN ('paid','void','cancelled')
)
DELETE FROM orders WHERE id IN (SELECT id FROM cold);
-- order_items/options/payments ikut terhapus via ON DELETE CASCADE
```
**Dampak:** mengubah pertumbuhan raw jadi **mendatar** (steady-state). **Risiko:** sedang → **wajib verifikasi export sukses sebelum DELETE**.

---

### Strategi 4 — Kontrol Bloat (`orders` sering di-UPDATE)
```sql
ALTER TABLE orders SET (fillfactor = 85);            -- ruang HOT-update → bloat turun
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor = 0.05,
                        autovacuum_vacuum_cost_delay = 2);
-- Reclaim satu kali (mengunci sebentar; lakukan saat sepi):
VACUUM (FULL, ANALYZE) orders;   -- atau pg_repack bila tak boleh lock
```
**Dampak:** −20–40% ukuran (reclaim sekali + regrowth lebih lambat).

---

### Strategi 5 — Diet Index
32 index terpasang; sebagian mungkin tak terpakai. Cari & drop yang `idx_scan = 0`:
```sql
SELECT relname AS tabel, indexrelname AS index, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS ukuran
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```
**Dampak:** −10–20% (index sering 30–40% total). **Risiko:** rendah bila cek dulu bukan UNIQUE/constraint.

---

### Strategi 6 — Otomasi + Monitoring (`pg_cron`)
```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Harian 02:00 — pangkas audit log + refresh rollup kemarin + vacuum
SELECT cron.schedule('nightly-maintenance', '0 2 * * *', $$
  DELETE FROM order_audit_log ...;         -- Strategi 1
  CALL refresh_sales_daily_summary();      -- Strategi 2
  VACUUM (ANALYZE) orders;
$$);
-- Bulanan — arsip cold + repack (dipicu manual dulu untuk aman)
```
Plus tabel monitor kecil: catat `pg_database_size` harian, alert di ambang **70% (350 MB)** & **85% (425 MB)**.

---

## Ringkasan Dampak & Urutan Eksekusi

| Urutan | Strategi | Dampak | Risiko | Migrasi |
|--------|----------|--------|--------|---------|
| 1 | Ukur baseline | — | none | (query saja) |
| 2 | Prune audit log + pg_cron | −25–30% growth | rendah | `083_retention_audit_log.sql` |
| 3 | Rollup harian + refresh job | buka jalan arsip | sedang | `084_sales_daily_summary.sql` |
| 4 | Bloat control (fillfactor/vacuum) | −20–40% ukuran | rendah | `085_bloat_control.sql` |
| 5 | Diet index | −10–20% | rendah | `086_index_diet.sql` (setelah observasi) |
| 6 | Arsip cold > 18 bln | growth → mendatar | sedang | `087_cold_archive.sql` (manual dulu) |

**Hasil gabungan:** dari "~2 tahun lalu penuh" (1 outlet, 150 order/hari) → **efektif tak penuh** (steady-state) selama retensi + arsip berjalan. Untuk multi-outlet, Strategi 2+3 yang paling menentukan.

## Catatan Penting
- **Jangan** DELETE raw sebelum rollup (Strategi 2) jalan & terverifikasi.
- **Jangan** DELETE cold (Strategi 3) sebelum export terbukti sukses.
- `VACUUM FULL` mengunci tabel — jalankan saat outlet tutup.
- Pertimbangkan: bila multi-outlet tumbuh banyak, free plan tetap perlu upgrade — strategi ini menunda, bukan menggantikan.

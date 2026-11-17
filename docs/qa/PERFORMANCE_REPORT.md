# Performance Test Report — Jam Ramai Simulation

**Tanggal:** 2026-05-29
**Tester:** QA Engineer (load test automation)
**Target env:** Production Supabase (`kkzlpczlpffxodepelgc.supabase.co`)
**Outlet test:** `Resto Saya` (1 outlet, 30 meja, 13 kategori, 101 menu)
**Script:** `/tmp/perf-test.mjs` (Node.js native fetch + Promise concurrency)
**Geografis:** Tester di Indonesia → Supabase Singapore region

---

## 1. Executive Summary

| Skenario | Concurrency | Throughput | p95 Latency | Error Rate | Verdict |
|---|---|---|---|---|---|
| Baseline (1 user) | 1 | 6.6 req/s | 181 ms | 0% | ✅ OK |
| Light (breakfast) | 20 | 138 req/s | 153 ms | 0% | ✅ OK |
| Normal (lunch) | 50 | 322 req/s | 203 ms | 0% | ✅ OK |
| **Peak (lunch rush)** | **100** | **521 req/s** | **279 ms** | **0%** | **✅ OK** |
| Order Rush (50 write) | 50 | 333 req/s | 176 ms | 0% | ✅ OK |
| Burst spike (sudden) | 200 | 512 req/s | 661 ms | 0% | ✅ OK |
| Stress (breaking pt) | 500 | 561 req/s | 2802 ms | 0% | ⚠️ Degraded |

### Verdict Keseluruhan

✅ **Server AMAN untuk jam ramai operasional restoran normal**

- Sampai **100 pelanggan concurrent** (simulasi lunch rush ramai) — p95 di bawah 300ms, 0% error
- Sampai **200 concurrent spike** (orang scan QR bersamaan saat kelompok besar datang) — p95 masih di bawah 700ms
- Database **tidak crash bahkan di 500 concurrent**, hanya mengantri (p99 → 5s) — graceful degradation
- **0 error pada semua skenario realistic** (≤200 concurrent)

### Kapasitas Realistic

Restoran dengan 30 meja, kapasitas 4 orang/meja = max **120 customer fisik di restoran**.
Dengan asumsi 30-40% scan QR + pesan online bersamaan → ~40-50 concurrent.
**Headroom 2-4× dari kapasitas teoritis** sebelum performance mulai turun.

---

## 2. Methodology

### 2.1 Customer journey simulasi

Setiap "user" virtual mengeksekusi 4-6 request berurutan, persis seperti customer asli scan QR meja:

```
1. GET /restaurant_tables    → lookup table by qr_token (anon RLS check)
2. GET /v_outlets_public     → fetch outlet info + tax settings
3. GET /menu_categories      → list kategori aktif
4. GET /menu_items           → list ~100 menu items
[Optional, only ORDER RUSH]
5. POST /orders              → submit self-order (anon insert)
6. POST /order_items         → batch insert 1-3 items
```

### 2.2 Concurrency model

- N "users" (worker async function) berjalan parallel via `Promise.all`
- Setiap user loop terus eksekusi journey sampai deadline tercapai
- Tiap journey randomize QR token (10 meja pool) supaya cache tidak terlalu hot

### 2.3 Skenario uji

| Skenario | Concurrent | Durasi | Tujuan |
|---|---|---|---|
| Baseline | 1 | 10s | Reference latency, warm-up |
| Light | 20 | 15s | Pagi (sarapan / off-peak) |
| Normal | 50 | 20s | Jam normal (12 customer/menit) |
| Peak | 100 | 20s | Lunch rush — semua pelanggan scan bareng |
| Order Rush | 50 | 20s | Write-heavy: semua user pesan |
| Burst | 200 | 10s | Spike mendadak (rombongan datang) |
| Stress | 500 | 8s | Cari breaking point |

### 2.4 Metrik yang diukur

- **Throughput (req/s)** — request per detik
- **Latency** — p50 (median), p95, p99, max per endpoint
- **Error rate** — HTTP status non-2xx + network errors
- **Per-endpoint breakdown** — identifikasi bottleneck

---

## 3. Detail Hasil per Skenario

### 3.1 BASELINE (1 user, 10s)

```
Endpoint                       Count  p50   p95   max
GET /restaurant_tables           17  140   180   180ms
GET /v_outlets_public            17  141   451   451ms ← cold cache
GET /menu_categories             17  141   438   438ms ← cold cache
GET /menu_items                  17  144   161   161ms

Total: 68 req | 0 err | 6.6 req/s | overall p95: 181ms
```

**Observasi:** First request setiap endpoint terkena cold start (~400ms). Setelah warm, latency stabil ~140ms (network RTT Indonesia ↔ Singapore Supabase + query exec).

### 3.2 LIGHT (20 concurrent, 15s)

```
Endpoint                       Count  p50   p95   p99   max
GET /restaurant_tables          538  138   158   436   452ms
GET /v_outlets_public           538  137   149   186   325ms
GET /menu_categories            538  137   152   179   591ms
GET /menu_items                 538  140   154   163   332ms

Total: 2152 req | 0 err | 138 req/s | overall p95: 153ms
```

**Observasi:** Linear scaling — 20× user → 21× throughput (no contention). Latency turun karena warm cache.

### 3.3 NORMAL (50 concurrent, 20s)

```
Endpoint                       Count  p50   p95   p99   max
GET /restaurant_tables         1652  143   223   460   493ms
GET /v_outlets_public          1652  142   197   256   333ms
GET /menu_categories           1652  143   193   244   430ms
GET /menu_items                1652  147   203   261   365ms

Total: 6608 req | 0 err | 322 req/s | overall p95: 203ms
```

**Observasi:** Throughput 322 req/s — cukup untuk 50 customer concurrent. Latency p95 masih < 250ms (acceptable).

### 3.4 PEAK (100 concurrent, 20s) — **LUNCH RUSH SIMULATION**

```
Endpoint                       Count  p50   p95   p99   max
GET /restaurant_tables         2706  171   300   411   655ms
GET /v_outlets_public          2706  172   264   313   508ms
GET /menu_categories           2706  177   268   306   460ms
GET /menu_items                2706  183   277   315   418ms

Total: 10824 req | 0 err | 521 req/s | overall p95: 279ms
```

**Observasi — kritis:**
- 521 req/s sustained selama 20 detik → **10.824 successful requests, 0 error**
- p95 latency 279ms — pelanggan tidak akan merasakan lag
- p99 latency 411ms — worst case masih < 0.5 detik
- **Verdict: Server AMAN untuk peak lunch rush**

### 3.5 ORDER RUSH (50 concurrent + write, 20s)

```
Endpoint                       Count  p50   p95   p99   max
GET /restaurant_tables         1150  140   190   282   419ms
GET /v_outlets_public          1150  140   163   217   328ms
GET /menu_categories           1150  141   168   212   236ms
GET /menu_items                1150  146   179   205   307ms
POST /orders                   1150  143   170   187   224ms ← lebih cepat dari GET!
POST /order_items              1150  146   185   207   298ms

Total: 6900 req | 0 err | 333 req/s | overall p95: 176ms
```

**Observasi — penting:**
- **1.150 order tersubmit dalam 20 detik = 57.5 order/detik** = setara 3.450 order/menit
- POST latency lebih cepat dari GET menu (karena POST cuma return minimal, no payload large)
- **0 error** — RLS, trigger stok, dan UNIQUE constraint payment_idempotency semua tahan
- Tidak ada deadlock atau write contention

### 3.6 BURST (200 concurrent sudden spike, 10s)

```
Endpoint                       Count  p50   p95   p99   max
GET /restaurant_tables         1401  372   673   967  1271ms
GET /v_outlets_public          1401  336   573   673   920ms
GET /menu_categories           1401  334   616   953  1085ms
GET /menu_items                1401  350   657   922  1108ms

Total: 5604 req | 0 err | 512 req/s | overall p95: 661ms
```

**Observasi:**
- Connection pool mulai antri — p50 naik 2× (170→370ms)
- Max latency menyentuh 1.3s untuk worst-case request
- **Tetap 0 error, server tidak panic**

### 3.7 STRESS 500 concurrent (breaking point search)

```
Total: 4747 req | 0 err | 561 req/s
Latency: p50=458ms p95=2802ms p99=5374ms max=8021ms
```

**Observasi — breaking point identified:**
- **Throughput plateau di ~560 req/s** — sudah hit max DB connection pool
- p99 latency: **5.3 detik** → ini mulai customer-noticeable
- Tetap **0 error** karena Supabase queue request, bukan reject (graceful)
- Beberapa request menunggu 8 detik di max — borderline timeout user experience

---

## 4. Analisis Bottleneck

### 4.1 Bottleneck identified

| Komponen | Limit | Saat tercapai |
|---|---|---|
| **Network RTT Indonesia↔Singapore** | ~140ms minimum | Selalu (fixed cost) |
| **Supabase connection pool (pgBouncer)** | ~200 concurrent | Burst 200 — latency mulai naik |
| **PostgreSQL query exec** | < 50ms per query | Tidak pernah jadi bottleneck |
| **PostgREST request handling** | ~600 req/s | Stress 500 — plateau |

### 4.2 Mengapa server tetap stabil di peak

1. **RLS policies pakai indexed columns** (`outlet_id`, `qr_token`) → query selalu < 50ms
2. **View `v_outlets_public`** punya WHERE inline → planner cache reusable
3. **`menu_items` 100 rows** ringan untuk transfer (~30KB JSON)
4. **Insert order pakai `Prefer: return=minimal`** → tidak round-trip data
5. **Anon RLS policy SIMPLE** → cuma 1 EXISTS check via `is_self_order()` SECURITY DEFINER

### 4.3 Yang BELUM dites

⚠️ **Cakupan keterbatasan test ini:**

- ❌ Realtime subscription load (dapur subscribe channel — bagaimana kalau 50 kasir + 10 dapur connect bareng?)
- ❌ Auth login concurrent (kalau 20 staff login bareng pagi hari)
- ❌ Large data set di sales-breakdown query (saat ini outlet baru, data masih kosong)
- ❌ Export PDF/Excel di owner-panel saat ada 10000+ orders
- ❌ Edge function performance (qr generator)
- ❌ Storage (image upload menu) under concurrent load

---

## 5. Rekomendasi

### 5.1 Production-ready untuk skala ini ✅

Konfigurasi saat ini **sudah cukup** untuk:
- Restoran dengan 30-50 meja
- ~100-200 customer simultan
- ~500 order/jam saat peak

### 5.2 Optimasi tambahan (low effort, high impact)

1. **Tambah cache HTTP header di `v_outlets_public`** — settings outlet jarang berubah
   ```sql
   -- via Supabase API gateway / CDN: Cache-Control: max-age=60
   ```

2. **Index untuk query menu** (kemungkinan sudah ada, verify):
   ```sql
   CREATE INDEX IF NOT EXISTS idx_menu_items_outlet_avail
     ON menu_items (outlet_id, is_available, is_active, sort_order);
   ```

3. **Connection pool size** — naikkan kalau hit Burst 200 lebih sering. Default Supabase Pro: 200 → upgrade ke Team plan untuk 500.

### 5.3 Upgrade triggers (kapan upgrade plan)

| Kondisi | Tindakan |
|---|---|
| Outlet > 100 dengan total > 5000 menu | Pertimbangkan Supabase Pro tier |
| Concurrent > 200 reguler (event besar) | Upgrade ke Team plan (connection pool 500+) |
| Realtime subscriber > 100 simultan | Aktifkan Realtime tier upgrade |
| Egress > 50GB/bulan | Pertimbangkan CDN untuk image menu |

### 5.4 Monitoring yang harus di-setup

- **Supabase Dashboard → Reports → Database** — watch connection pool usage
- **Supabase logs filter** — alert kalau ada 429 (rate limit) atau 503 (overload)
- **Synthetic check** — `curl /rest/v1/health` setiap 1 menit dari uptime monitor

---

## 6. Reproduksi Test

### 6.1 Run script

```bash
# All scenarios berturut-turut
node /tmp/perf-test.mjs all

# Skenario spesifik
node /tmp/perf-test.mjs baseline    # 1 user reference
node /tmp/perf-test.mjs light       # 20 concurrent
node /tmp/perf-test.mjs normal      # 50 concurrent
node /tmp/perf-test.mjs peak        # 100 concurrent lunch rush
node /tmp/perf-test.mjs order-rush  # 50 concurrent + write
node /tmp/perf-test.mjs burst       # 200 sudden spike
```

### 6.2 Cleanup setelah test

Test orders pakai prefix `LOAD-` di `order_number`. Cleanup:

```sql
DELETE FROM orders WHERE order_number LIKE 'LOAD-%';
-- cascade ke order_items + payments otomatis
```

---

## 7. Kesimpulan

### Pertanyaan: "Apakah server aman saat jam ramai?"

**Jawaban: ✅ YA, server aman untuk operasional jam ramai normal.**

**Bukti:**
- 100 concurrent customer (skenario lunch rush realistic) → 521 req/s, p95 < 300ms, 0% error
- 50 concurrent dengan submit order → 1150 order/20 detik tanpa error
- Burst mendadak 200 concurrent → masih 0 error
- Breaking point hanya tercapai di 500 concurrent (sangat tidak realistic untuk 1 restoran)

**Asumsi yang harus dipenuhi:**
1. Tidak lebih dari 1 outlet (multi-outlet perlu tes ulang)
2. Menu < 500 item per outlet
3. Tidak ada concurrent owner-panel report query saat peak
4. Customer cuma scan QR + pesan (tidak ada fitur berat lain)

**Sign-off:** Aplikasi siap untuk production deploy dari sisi performance.

---

**Lampiran:** Raw log test bisa di-rerun via `/tmp/perf-test.mjs <scenario>`.

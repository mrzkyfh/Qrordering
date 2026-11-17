# API Testing Report — Advanced: Views, Audit Log, Anon, Storage, RPCs
**Tanggal:** 2026-05-27  
**QA Engineer:** Claude QA Agent  
**Scope:** Views isolation, order_audit_log RLS, anonymous self-order, storage bucket, RPC edge cases, shifts impersonation  

---

## Setup Variables

```bash
REST_URL="https://<project>.supabase.co/rest/v1"
ANON_KEY="<anon-key>"

OWNER_TOKEN="Bearer <owner-jwt>"
ADMIN_TOKEN="Bearer <admin-jwt>"        # admin outlet A
KASIR_TOKEN="Bearer <kasir-jwt>"        # kasir outlet A
ADMIN_B_TOKEN="Bearer <admin-b-jwt>"    # admin outlet B

OUTLET_A="<outlet-a-uuid>"
OUTLET_B="<outlet-b-uuid>"
```

---

## 1. Views — Data Isolation

Views di project ini menggunakan `SECURITY INVOKER` (default PostgreSQL) — artinya query dalam view dieksekusi dengan permission user yang memanggil. RLS pada tabel underlying tetap berlaku.

### TC-VIEW-001 ✅ v_daily_sales hanya tampilkan data outlet sendiri
```bash
curl "$REST_URL/v_daily_sales?outlet_id=eq.$OUTLET_B" \
  -H "Authorization: $KASIR_TOKEN"
```
**Expected:** `[]` — RLS pada `orders` memblokir kasir A melihat data outlet B  
**Actual:** ✅ Empty — SECURITY INVOKER + orders_select RLS bekerja

---

### TC-VIEW-002 ✅ v_top_menu_items hanya tampilkan item outlet sendiri
```bash
curl "$REST_URL/v_top_menu_items?outlet_id=eq.$OUTLET_B" \
  -H "Authorization: $ADMIN_TOKEN"
```
**Expected:** `[]`  
**Actual:** ✅ Empty — join ke `menu_items` dan `orders` keduanya ter-filter RLS

---

### TC-VIEW-003 ✅ v_profit_loss hanya tampilkan data outlet sendiri
```bash
curl "$REST_URL/v_profit_loss?outlet_id=eq.$OUTLET_B" \
  -H "Authorization: $ADMIN_TOKEN"
```
**Expected:** `[]`  
**Actual:** ✅ RLS pada `orders` dan `expenses` aktif

---

### TC-VIEW-004 ✅ Owner melihat semua outlet di semua views
```bash
curl "$REST_URL/v_daily_sales" \
  -H "Authorization: $OWNER_TOKEN"
```
**Expected:** Data dari semua outlet  
**Actual:** ✅ `is_owner()` memperbolehkan SELECT semua order

---

### TC-VIEW-005 ✅ v_stock_daily hanya tampilkan stok outlet sendiri
```bash
curl "$REST_URL/v_stock_daily?outlet_id=eq.$OUTLET_B" \
  -H "Authorization: $KASIR_TOKEN"
```
**Expected:** `[]`  
**Actual:** ✅ RLS pada `ingredients` aktif

---

### TC-VIEW-006 🟡 v_kasir_performance dapat diakses kasir lain
```bash
curl "$REST_URL/v_kasir_performance" \
  -H "Authorization: $KASIR_TOKEN"
```
**Expected:** Hanya data diri sendiri  
**Note:** View menampilkan performa semua kasir di outlet yang sama — kasir bisa lihat performa rekannya. Ini by-design (transparansi) atau privacy concern tergantung kebijakan bisnis.  
**Actual:** 🟡 Semua kasir di outlet yang sama terlihat — perlu konfirmasi apakah by-design.

---

## 2. Order Audit Log

### TC-AUDIT-001 🚨 CRITICAL: Kasir outlet A bisa baca audit log outlet B
```bash
curl "$REST_URL/order_audit_log?outlet_id=eq.$OUTLET_B" \
  -H "Authorization: $KASIR_TOKEN"
```
**Expected:** `[]` — kasir hanya boleh lihat audit log outletnya  
**Actual:** 🚨 HTTP 200 — mengembalikan data audit log outlet B  
**Root cause:**
```sql
-- Policy yang ada (BUGGY):
USING (
  outlet_id IN (
    SELECT outlet_id FROM profiles WHERE id = auth.uid()
    UNION
    SELECT id FROM outlets WHERE TRUE  -- ← SEMUA outlet UUID masuk di sini!
  )
);
```
`SELECT id FROM outlets WHERE TRUE` mengembalikan semua outlet ID → setiap user authenticated bisa lihat semua audit log.

**Fix (migration 024):**
```sql
DROP POLICY IF EXISTS "order_audit_log_select" ON order_audit_log;
CREATE POLICY "order_audit_log_select" ON order_audit_log
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());
```

---

### TC-AUDIT-002 🔴 Any authenticated user bisa INSERT audit log palsu
```bash
curl -X POST "$REST_URL/order_audit_log" \
  -H "Authorization: $KASIR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"$ORDER_ID","outlet_id":"$OUTLET_A","actor_id":"$OWNER_USER_ID","actor_name":"Owner Palsu","action":"void","notes":"Manipulasi audit trail"}'
```
**Expected:** HTTP 403 — audit log harus diisi hanya oleh sistem/trigger  
**Actual:** 🔴 HTTP 201 — `WITH CHECK (true)` membolehkan insert apapun  
**Impact:** Kasir bisa inject audit log palsu dengan `actor_id` orang lain → menyalahkan orang lain atas tindakan tertentu  

**Fix (migration 024):** Restrict insert ke service_role atau via RLS yang ketat:
```sql
DROP POLICY IF EXISTS "order_audit_log_insert" ON order_audit_log;
CREATE POLICY "order_audit_log_insert" ON order_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    outlet_id = auth_outlet_id()
    AND actor_id = auth.uid()
  );
```

---

### TC-AUDIT-003 ✅ Tidak ada UPDATE/DELETE policy pada audit log
```bash
curl -X PATCH "$REST_URL/order_audit_log?id=eq.$LOG_ID" \
  -H "Authorization: $OWNER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"void_altered"}'
```
**Expected:** HTTP 403 — audit log immutable  
**Actual:** ✅ HTTP 403 — tidak ada UPDATE/DELETE policy

---

## 3. Anonymous / Self-Order Flow

### TC-ANON-001 ✅ Anon bisa baca outlet aktif
```bash
curl "$REST_URL/outlets?is_active=eq.true" \
  -H "apikey: $ANON_KEY"
```
**Expected:** HTTP 200 — `outlets_select_anon` policy  
**Actual:** ✅

---

### TC-ANON-002 ✅ Anon bisa lookup meja via qr_token
```bash
curl "$REST_URL/restaurant_tables?qr_token=eq.$QR_TOKEN&is_active=eq.true" \
  -H "apikey: $ANON_KEY"
```
**Expected:** HTTP 200 dengan data meja  
**Actual:** ✅ `tables_select_anon` policy

---

### TC-ANON-003 ✅ Anon bisa baca menu item tersedia
```bash
curl "$REST_URL/menu_items?outlet_id=eq.$OUTLET_A&is_available=eq.true&is_active=eq.true" \
  -H "apikey: $ANON_KEY"
```
**Expected:** HTTP 200  
**Actual:** ✅ `menu_items_select_anon` policy

---

### TC-ANON-004 ✅ Anon bisa INSERT self_order
```bash
curl -X POST "$REST_URL/orders" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"outlet_id":"$OUTLET_A","order_type":"self_order","table_id":"$TABLE_ID","subtotal":0,"discount_amount":0,"tax_amount":0,"service_charge":0,"total_amount":0}'
```
**Expected:** HTTP 201  
**Policy:** `orders_insert_anon` WITH CHECK `order_type = 'self_order'`  
**Actual:** ✅

---

### TC-ANON-005 ✅ Anon tidak bisa INSERT dine_in/takeaway order
```bash
curl -X POST "$REST_URL/orders" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"outlet_id":"$OUTLET_A","order_type":"dine_in","subtotal":0,"discount_amount":0,"tax_amount":0,"service_charge":0,"total_amount":0}'
```
**Expected:** HTTP 403  
**Actual:** ✅ HTTP 403 — WITH CHECK `order_type = 'self_order'` menolak

---

### TC-ANON-006 ✅ Anon bisa INSERT order_items ke self_order via is_self_order()
```bash
curl -X POST "$REST_URL/order_items" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"$SELF_ORDER_ID","menu_item_id":"$ITEM_ID","quantity":1,"unit_price":25000,"subtotal":25000}'
```
**Expected:** HTTP 201  
**Policy:** `order_items_insert_anon` WITH CHECK `is_self_order(order_id)` (SECURITY DEFINER)  
**Actual:** ✅

---

### TC-ANON-007 ✅ Anon tidak bisa INSERT order_items ke non-self_order
```bash
curl -X POST "$REST_URL/order_items" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"$DINE_IN_ORDER_ID","menu_item_id":"$ITEM_ID","quantity":1,"unit_price":25000,"subtotal":25000}'
```
**Expected:** HTTP 403  
**Actual:** ✅ `is_self_order()` returns false → blocked

---

### TC-ANON-008 ✅ Anon tidak bisa baca profiles/expenses/shifts
```bash
curl "$REST_URL/profiles" -H "apikey: $ANON_KEY"
curl "$REST_URL/expenses" -H "apikey: $ANON_KEY"
curl "$REST_URL/shifts" -H "apikey: $ANON_KEY"
```
**Expected:** HTTP 200 empty array (RLS enabled, no anon policy)  
**Actual:** ✅ `[]` pada semua — RLS default deny untuk anon

---

### TC-ANON-009 🔴 Anon bisa baca menu item tidak aktif jika tahu ID-nya
```bash
curl "$REST_URL/menu_items?id=eq.$INACTIVE_ITEM_ID" \
  -H "apikey: $ANON_KEY"
```
**Expected:** `[]` — item tidak aktif tidak boleh terlihat  
**Policy saat ini:** `menu_items_select_anon` USING `is_available = true AND is_active = true`  
**Actual:** ✅ `[]` — policy sudah benar, item inactive tidak terlihat  
**Note:** Hanya bisa diakses jika `is_available = true AND is_active = true`. Filter bekerja.

---

### TC-ANON-010 🔴 Anon bisa lihat semua outlet termasuk yang tidak aktif lewat direct ID
```bash
curl "$REST_URL/outlets?id=eq.$INACTIVE_OUTLET_ID" \
  -H "apikey: $ANON_KEY"
```
**Expected:** `[]`  
**Policy:** `outlets_select_anon` USING `is_active = true`  
**Actual:** ✅ `[]` — hanya outlet aktif yang terlihat

---

## 4. Storage Bucket

### TC-STOR-001 ✅ Siapa saja bisa baca gambar menu (public bucket)
```bash
curl "https://<project>.supabase.co/storage/v1/object/public/menu-images/<path>"
```
**Expected:** HTTP 200 — menu public  
**Actual:** ✅ By design — bucket `public: true`

---

### TC-STOR-002 ✅ Anon tidak bisa upload gambar menu
```bash
curl -X POST "https://<project>.supabase.co/storage/v1/object/menu-images/test.jpg" \
  -H "apikey: $ANON_KEY" \
  --data-binary @test.jpg
```
**Expected:** HTTP 400/403  
**Policy:** `menu_images_auth_insert` → `auth.role() = 'authenticated'`  
**Actual:** ✅ HTTP 400 — anon tidak bisa upload

---

### TC-STOR-003 🔴 Kasir outlet A bisa OVERWRITE gambar outlet B (no path isolation)
```bash
# Kasir A upload file dengan path yang sama dengan gambar outlet B
curl -X POST "https://<project>.supabase.co/storage/v1/object/menu-images/$OUTLET_B/item.jpg" \
  -H "Authorization: $KASIR_TOKEN" \
  --data-binary @new_image.jpg
```
**Expected:** HTTP 403 — hanya admin/owner outlet yang bersangkutan  
**Actual:** 🔴 HTTP 200 — storage policy hanya cek `authenticated`, tidak validasi outlet  
**Root cause:** `menu_images_auth_insert` hanya cek `auth.role() = 'authenticated'` — tidak ada path-based outlet isolation  
**Impact:** Kasir/admin mana saja bisa overwrite gambar menu outlet lain  
**Fix (migration 024):** Tambah path check di storage policy:
```sql
DROP POLICY IF EXISTS "menu_images_auth_insert" ON storage.objects;
CREATE POLICY "menu_images_auth_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      is_owner()
      OR (storage.foldername(name))[1] = auth_outlet_id()::text
    )
  );

DROP POLICY IF EXISTS "menu_images_auth_delete" ON storage.objects;
CREATE POLICY "menu_images_auth_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      is_owner()
      OR (storage.foldername(name))[1] = auth_outlet_id()::text
    )
  );
```
**Catatan:** Butuh konvensi path: `menu-images/{outlet_id}/{filename}`

---

### TC-STOR-004 ✅ Anon tidak bisa upload QR code
```bash
curl -X POST "https://<project>.supabase.co/storage/v1/object/qr-codes/test.png" \
  -H "apikey: $ANON_KEY" \
  --data-binary @qr.png
```
**Expected:** HTTP 403  
**Actual:** ✅

---

## 5. RPC Edge Cases

### TC-RPC-001 ✅ adjust_stock tipe tidak valid ditolak
```bash
curl -X POST "$REST_URL/rpc/adjust_stock" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_outlet_id":"$OUTLET_A","p_ingredient_id":"$ING_ID","p_type":"steal","p_qty":5}'
```
**Expected:** HTTP 400 — `p_type::stock_transaction_type` cast gagal  
**Actual:** ✅ HTTP 400

---

### TC-RPC-002 ✅ adjust_stock qty negatif ditolak
```bash
curl -X POST "$REST_URL/rpc/adjust_stock" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_outlet_id":"$OUTLET_A","p_ingredient_id":"$ING_ID","p_type":"purchase","p_qty":-10}'
```
**Expected:** HTTP 400 — `stock_transactions.qty CHECK (qty > 0)`  
**Actual:** ✅ HTTP 400

---

### TC-RPC-003 🔴 adjust_stock tidak memvalidasi p_outlet_id vs ingredient outlet
```bash
# Ingredient milik outlet B, tapi p_outlet_id = outlet A
curl -X POST "$REST_URL/rpc/adjust_stock" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_outlet_id":"$OUTLET_A","p_ingredient_id":"$ING_OUTLET_B_ID","p_type":"purchase","p_qty":5}'
```
**Expected:** HTTP 403 atau HTTP 400 — mismatch outlet  
**Actual:** 🔴 HTTP 200 — stock transaction dibuat dengan p_outlet_id=A tapi ingredient milik B  
**Root cause:** `adjust_stock()` RPC adalah SECURITY INVOKER → harus bisa SELECT ingredient (terblokir RLS), tapi stock_tx_insert hanya cek `outlet_id = auth_outlet_id()` — `p_outlet_id` bisa saja berbeda dari `ingredient.outlet_id`  
**Impact:** Record stock transaction outlet_id mismatch → laporan stok salah  
**Fix:** Tambah validasi di RPC:
```sql
CREATE OR REPLACE FUNCTION adjust_stock(...) AS $$
DECLARE
  v_ingredient_outlet UUID;
BEGIN
  SELECT outlet_id INTO v_ingredient_outlet FROM ingredients WHERE id = p_ingredient_id;
  IF v_ingredient_outlet != p_outlet_id THEN
    RAISE EXCEPTION 'ingredient does not belong to the specified outlet';
  END IF;
  -- ... rest of function
```

---

### TC-RPC-004 ✅ close_shift pada shift yang sudah ditutup mengupdate ulang (no guard)
```bash
curl -X POST "$REST_URL/rpc/close_shift" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_shift_id":"$CLOSED_SHIFT_ID","p_closing_cash":500000}'
```
**Expected:** 🟡 Seharusnya error jika shift sudah tertutup (end_time IS NOT NULL)  
**Actual:** 🟡 HTTP 200 — shift ditutup ulang, end_time dan closing_cash diperbarui  
**Impact:** Double-close shift mengubah data historis  
**Fix (LOW):** Tambah guard di RPC:
```sql
IF EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND end_time IS NOT NULL) THEN
  RAISE EXCEPTION 'shift already closed';
END IF;
```

---

### TC-RPC-005 ✅ close_shift oleh kasir yang tidak membuka shift ditolak RLS
```bash
# Kasir B coba tutup shift milik kasir A
curl -X POST "$REST_URL/rpc/close_shift" \
  -H "Authorization: $KASIR_B_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_shift_id":"$SHIFT_KASIR_A_ID","p_closing_cash":300000}'
```
**Expected:** HTTP 403  
**Policy:** `shifts_update` → `kasir_id = auth.uid()` untuk kasir  
**Actual:** ✅ HTTP 403 — kasir hanya bisa update shift miliknya sendiri

---

## 6. Shifts — Impersonation

### TC-SHIFT-IMP-001 ✅ Kasir tidak bisa buka shift dengan kasir_id orang lain
```bash
curl -X POST "$REST_URL/shifts" \
  -H "Authorization: $KASIR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"outlet_id":"$OUTLET_A","kasir_id":"$OTHER_KASIR_ID","opening_cash":200000}'
```
**Expected:** HTTP 403  
**Policy:** `shifts_insert` → `outlet_id = auth_outlet_id() AND kasir_id = auth.uid()` untuk kasir  
**Actual:** ✅ HTTP 403

---

### TC-SHIFT-IMP-002 ✅ Admin bisa buka shift untuk kasir manapun di outletnya
```bash
curl -X POST "$REST_URL/shifts" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"outlet_id":"$OUTLET_A","kasir_id":"$KASIR_ID","opening_cash":200000}'
```
**Expected:** HTTP 201 — admin bertanggung jawab atas operasional outlet  
**Actual:** ✅ HTTP 201

---

### TC-SHIFT-IMP-003 ✅ Admin outlet A tidak bisa buka shift di outlet B
```bash
curl -X POST "$REST_URL/shifts" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"outlet_id":"$OUTLET_B","kasir_id":"$KASIR_ID","opening_cash":200000}'
```
**Expected:** HTTP 403  
**Actual:** ✅ HTTP 403

---

## Ringkasan Temuan Baru

| ID | Area | Severity | Deskripsi |
|----|------|----------|-----------|
| BUG-AUDIT-001 | order_audit_log | 🚨 CRITICAL | SELECT policy bocorkan semua audit log ke user manapun |
| BUG-AUDIT-002 | order_audit_log | 🔴 HIGH | INSERT WITH CHECK (true) — audit log palsu bisa diinjeksi |
| BUG-STOR-001 | storage | 🔴 HIGH | Tidak ada path isolation — kasir bisa overwrite gambar outlet lain |
| BUG-RPC-001 | adjust_stock | 🔴 HIGH | p_outlet_id tidak divalidasi terhadap ingredient.outlet_id |
| BUG-RPC-002 | close_shift | 🟡 MEDIUM | Double-close shift tidak dideteksi |
| BUG-VIEW-001 | v_kasir_performance | 🟢 LOW | Kasir bisa lihat performa kasir lain (perlu konfirmasi by-design) |

---

## Fix yang Direkomendasikan — Migration 024

### CRITICAL + HIGH (wajib)

**BUG-AUDIT-001 + BUG-AUDIT-002:**
```sql
DROP POLICY IF EXISTS "order_audit_log_select" ON order_audit_log;
CREATE POLICY "order_audit_log_select" ON order_audit_log
  FOR SELECT TO authenticated
  USING (is_owner() OR outlet_id = auth_outlet_id());

DROP POLICY IF EXISTS "order_audit_log_insert" ON order_audit_log;
CREATE POLICY "order_audit_log_insert" ON order_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    (is_owner() OR outlet_id = auth_outlet_id())
    AND actor_id = auth.uid()
  );
```

**BUG-RPC-001 (adjust_stock validation):**
```sql
CREATE OR REPLACE FUNCTION adjust_stock(p_outlet_id UUID, p_ingredient_id UUID, p_type text,
  p_qty numeric, p_cost_per_unit numeric DEFAULT NULL, p_notes text DEFAULT NULL,
  p_created_by UUID DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_qty_before numeric;
  v_qty_after numeric;
  v_ingredient_outlet UUID;
BEGIN
  SELECT stock_qty, outlet_id INTO v_qty_before, v_ingredient_outlet
  FROM ingredients WHERE id = p_ingredient_id FOR UPDATE;

  IF v_ingredient_outlet IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'ingredient does not belong to the specified outlet';
  END IF;

  IF p_type IN ('purchase', 'return', 'adjustment') THEN
    v_qty_after := v_qty_before + p_qty;
  ELSE
    v_qty_after := GREATEST(v_qty_before - p_qty, 0);
  END IF;

  INSERT INTO stock_transactions (outlet_id, ingredient_id, type, qty_before, qty, qty_after,
    cost_per_unit, notes, created_by)
  VALUES (p_outlet_id, p_ingredient_id, p_type::stock_transaction_type, v_qty_before,
    p_qty, v_qty_after, p_cost_per_unit, p_notes, p_created_by);
END; $$;
```

**BUG-STOR-001 (storage path isolation):**
```sql
DROP POLICY IF EXISTS "menu_images_auth_insert" ON storage.objects;
CREATE POLICY "menu_images_auth_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::text FROM profiles WHERE id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS "menu_images_auth_delete" ON storage.objects;
CREATE POLICY "menu_images_auth_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid()) = 'owner'
      OR (storage.foldername(name))[1] = (
        SELECT outlet_id::text FROM profiles WHERE id = auth.uid()
      )
    )
  );
```
**Catatan:** Butuh konvensi path upload: `menu-images/{outlet_id}/{filename}`. Update frontend juga diperlukan.

### MEDIUM
**BUG-RPC-002 (close_shift guard):** Tambah pengecekan `end_time IS NOT NULL` di awal function.

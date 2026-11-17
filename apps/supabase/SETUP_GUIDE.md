# Panduan Setup Supabase

## Urutan eksekusi

Jalankan file SQL berikut satu per satu di **Supabase Dashboard → SQL Editor**.
Urutan ini WAJIB diikuti karena ada dependency antar file.

---

## 1. Buka SQL Editor

Buka: https://supabase.com/dashboard/project/kkzlpczlpffxodepelgc/sql/new

---

## 2. Jalankan migration secara berurutan

### Step 1 — Types (Enum)
Copy-paste isi file `001_types.sql` → klik **Run**

### Step 2 — Tables
Copy-paste isi file `002_tables.sql` → klik **Run**

### Step 3 — Views
Copy-paste isi file `003_views.sql` → klik **Run**

### Step 4 — Functions & Triggers
Copy-paste isi file `004_functions_triggers.sql` → klik **Run**

### Step 5 — RLS Policies
Copy-paste isi file `005_rls.sql` → klik **Run**

### Step 6 — Storage Buckets
Copy-paste isi file `006_storage.sql` → klik **Run**

---

## 3. Buat User Owner Pertama

Setelah semua migration selesai, buat user owner melalui SQL Editor:

```sql
-- Panggil setelah user dibuat via Auth dashboard atau signup
UPDATE profiles
SET role = 'owner', full_name = 'Nama Owner'
WHERE id = (SELECT id FROM auth.users WHERE email = 'email@kamu.com');
```

Atau buat user via **Authentication → Users → Add user**, lalu update role-nya.

---

## 4. Buat Outlet Pertama

```sql
INSERT INTO outlets (name, address, phone, city)
VALUES ('Nama Restoran', 'Alamat Lengkap', '08xxx', 'Jakarta');
```

Lalu assign outlet ke profile owner:

```sql
UPDATE profiles
SET outlet_id = (SELECT id FROM outlets LIMIT 1)
WHERE role = 'owner';
```

---

## 5. Deploy Edge Function

### Install Supabase CLI

```bash
# Windows (scoop)
scoop install supabase

# atau npm
npm install -g supabase
```

### Login dan link project

```bash
supabase login
supabase link --project-ref kkzlpczlpffxodepelgc
```

### Set environment variable untuk Edge Function

Di Supabase Dashboard → **Settings → Edge Functions → Environment Variables**:

| Key | Value |
|-----|-------|
| `APP_URL` | `https://qrordering.pages.dev` |

(`SUPABASE_URL` dan `SUPABASE_SERVICE_ROLE_KEY` sudah tersedia otomatis di Edge Function)

### Deploy fungsi

```bash
# Jalankan dari root repository; project Supabase berada di apps/supabase.
supabase functions deploy create-staff --workdir apps
supabase functions deploy clock-in --workdir apps
supabase functions deploy change-device-password --workdir apps
supabase functions deploy change-staff-password --workdir apps
supabase functions deploy archive-orders --workdir apps
supabase functions deploy transaction-archive --workdir apps
```

---

## 6. Konfigurasi Auth

Di Supabase Dashboard → **Authentication → URL Configuration**:

- **Site URL**: `https://qrordering.pages.dev`
- **Redirect URLs**: `https://qrordering.pages.dev/**`

Di **Authentication → Providers → Email**:
- Enable Email provider
- Disable "Confirm email" jika ingin login langsung tanpa verifikasi (untuk dev)

---

## 7. Verifikasi Setup

Jalankan query ini untuk cek apakah semua tabel sudah ada:

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
```

Hasilnya harus ada: expenses, ingredients, menu_categories, menu_items, order_items, orders, outlets, payments, promos, profiles, restaurant_tables, shifts, stock_transactions, vouchers

Cek views:

```sql
SELECT table_name
FROM information_schema.views
WHERE table_schema = 'public';
```

Hasilnya harus ada: v_daily_sales, v_kasir_performance, v_low_stock, v_payment_summary, v_profit_loss, v_top_menu_items

---

## Urutan Lengkap (Copy-paste ke terminal)

Jika pakai Supabase CLI untuk apply semua migration sekaligus:

```bash
cd apps/supabase
supabase db push
```

> Catatan: `supabase db push` akan menjalankan semua file di folder `migrations/` secara berurutan berdasarkan nama file.

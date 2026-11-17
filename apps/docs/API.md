# Dokumentasi API & Database

**Versi:** 1.0.0  
**Terakhir diperbarui:** 27 Mei 2026  
**Backend:** Supabase (PostgreSQL + REST API auto-generated)

---

## Daftar Isi

1. [Autentikasi](#autentikasi)
2. [Koneksi Supabase](#koneksi-supabase)
3. [Tabel Database](#tabel-database)
4. [Views (Laporan)](#views-laporan)
5. [Edge Functions](#edge-functions)
6. [Row Level Security (RLS)](#row-level-security-rls)
7. [Enum Types](#enum-types)
8. [Contoh Query](#contoh-query)

---

## Autentikasi

Sistem menggunakan **Supabase Auth** dengan JWT token. Semua request ke API memerlukan header:

```
Authorization: Bearer <jwt-token>
```

### Login

```javascript
const { data, error } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'password123'
})
// data.session.access_token → gunakan sebagai Bearer token
```

### Logout

```javascript
await supabase.auth.signOut()
```

---

## Koneksi Supabase

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.VITE_SUPABASE_ANON_KEY
)
```

Supabase menyediakan **REST API otomatis** untuk setiap tabel. Endpoint dasar:

```
https://<project-ref>.supabase.co/rest/v1/<table-name>
```

---

## Tabel Database

### `outlets` — Data Outlet/Cabang

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `name` | TEXT | Nama outlet |
| `address` | TEXT | Alamat outlet |
| `phone` | TEXT | Nomor telepon |
| `city` | TEXT | Kota |
| `logo_url` | TEXT | URL logo |
| `is_active` | BOOLEAN | Status aktif |
| `settings` | JSONB | Konfigurasi (pajak, service charge, mata uang, footer struk) |
| `loyalty_settings` | JSONB | Konfigurasi program loyalty |
| `created_at` | TIMESTAMPTZ | Waktu dibuat |
| `updated_at` | TIMESTAMPTZ | Waktu terakhir diubah |

**Struktur `settings`:**
```json
{
  "tax_percent": 11,
  "service_charge_percent": 5,
  "currency": "IDR",
  "receipt_footer": "Terima kasih telah berkunjung!"
}
```

**Struktur `loyalty_settings`:**
```json
{
  "points_per_rupiah": 1,
  "redeem_rate": 100,
  "tier_threshold": {
    "silver": 1000,
    "gold": 5000,
    "platinum": 20000
  }
}
```

---

### `profiles` — Data Pengguna

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | FK ke `auth.users` |
| `outlet_id` | UUID | FK ke `outlets` |
| `role` | user_role | Role pengguna |
| `full_name` | TEXT | Nama lengkap |
| `phone` | TEXT | Nomor HP |
| `avatar_url` | TEXT | URL foto profil |
| `is_active` | BOOLEAN | Status aktif |
| `last_login_at` | TIMESTAMPTZ | Waktu login terakhir |

---

### `restaurant_tables` — Data Meja

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `table_number` | TEXT | Nomor/nama meja |
| `area` | TEXT | Area (Indoor, Outdoor, VIP) |
| `capacity` | INTEGER | Kapasitas duduk |
| `status` | table_status | Status meja |
| `qr_token` | TEXT | Token unik QR code (UNIQUE) |
| `qr_code_url` | TEXT | URL gambar QR code |
| `qr_generated_at` | TIMESTAMPTZ | Waktu QR dibuat |
| `is_active` | BOOLEAN | Status aktif |

---

### `menu_categories` — Kategori Menu

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `name` | TEXT | Nama kategori |
| `icon` | TEXT | Emoji/ikon kategori |
| `sort_order` | INTEGER | Urutan tampilan |
| `is_active` | BOOLEAN | Status aktif |

---

### `menu_items` — Item Menu

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `category_id` | UUID | FK ke `menu_categories` |
| `name` | TEXT | Nama menu |
| `description` | TEXT | Deskripsi |
| `price` | NUMERIC(12,2) | Harga (>= 0) |
| `image_url` | TEXT | URL gambar |
| `is_available` | BOOLEAN | Tersedia untuk dipesan |
| `is_active` | BOOLEAN | Status aktif (tidak terhapus) |
| `is_featured` | BOOLEAN | Menu unggulan |
| `preparation_time` | INTEGER | Estimasi waktu (menit) |
| `tags` | TEXT[] | Array tag |
| `variants` | JSONB | Varian harga/pilihan |
| `sort_order` | INTEGER | Urutan tampilan |

---

### `orders` — Data Pesanan

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `shift_id` | UUID | FK ke `shifts` |
| `table_id` | UUID | FK ke `restaurant_tables` |
| `order_number` | TEXT | Nomor pesanan (e.g., ORD-20260527-0001) |
| `order_type` | order_type | Tipe pesanan |
| `status` | order_status | Status pesanan |
| `customer_name` | TEXT | Nama pelanggan |
| `subtotal` | NUMERIC(12,2) | Subtotal sebelum pajak |
| `discount_amount` | NUMERIC(12,2) | Total diskon |
| `tax_amount` | NUMERIC(12,2) | Pajak |
| `service_charge` | NUMERIC(12,2) | Service charge |
| `total_amount` | NUMERIC(12,2) | Total akhir |
| `stock_deducted` | BOOLEAN | Apakah stok sudah dipotong |
| `created_by` | UUID | FK ke `profiles` |
| `created_at` | TIMESTAMPTZ | Waktu dibuat |

---

### `order_items` — Item dalam Pesanan

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `order_id` | UUID | FK ke `orders` |
| `menu_item_id` | UUID | FK ke `menu_items` |
| `quantity` | INTEGER | Jumlah (> 0) |
| `unit_price` | NUMERIC(12,2) | Harga saat dipesan |
| `subtotal` | NUMERIC(12,2) | quantity × unit_price |
| `notes` | TEXT | Catatan khusus |

---

### `payments` — Data Pembayaran

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `order_id` | UUID | FK ke `orders` |
| `outlet_id` | UUID | FK ke `outlets` |
| `method` | payment_method | Metode pembayaran |
| `amount` | NUMERIC(12,2) | Jumlah dibayar (> 0) |
| `reference_number` | TEXT | Nomor referensi (QRIS, transfer) |
| `paid_at` | TIMESTAMPTZ | Waktu pembayaran |

---

### `ingredients` — Bahan Baku

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `name` | TEXT | Nama bahan |
| `unit` | TEXT | Satuan (gr, kg, ml, pcs) |
| `cost_per_unit` | NUMERIC(12,2) | Harga beli per satuan |
| `stock_qty` | NUMERIC(10,3) | Stok saat ini |
| `min_stock_qty` | NUMERIC(10,3) | Stok minimum (alert) |
| `is_active` | BOOLEAN | Status aktif |

---

### `menu_recipes` — Resep Menu

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `menu_item_id` | UUID | FK ke `menu_items` |
| `ingredient_id` | UUID | FK ke `ingredients` |
| `qty_per_portion` | NUMERIC | Jumlah bahan per porsi (> 0) |

**Catatan:** Saat order berstatus `preparing`, trigger otomatis memanggil `deduct_stock_for_order()`. Saat `cancelled`/`void`, stok dikembalikan via `restore_stock_for_order()`.

---

### `shifts` — Sesi Kasir

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `kasir_id` | UUID | FK ke `profiles` |
| `start_time` | TIMESTAMPTZ | Waktu buka shift |
| `end_time` | TIMESTAMPTZ | Waktu tutup shift (null = masih buka) |
| `opening_cash` | NUMERIC(12,2) | Kas awal |
| `closing_cash` | NUMERIC(12,2) | Kas akhir (aktual) |
| `expected_cash` | NUMERIC(12,2) | Kas yang seharusnya |
| `cash_difference` | NUMERIC(12,2) | Selisih kas |
| `notes` | TEXT | Catatan shift |

---

### `promos` — Promo

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `name` | TEXT | Nama promo |
| `type` | promo_type | Jenis promo |
| `value` | NUMERIC(12,2) | Nilai diskon |
| `min_order` | NUMERIC(12,2) | Minimum order |
| `max_discount` | NUMERIC(12,2) | Maksimum diskon |
| `start_date` | DATE | Tanggal mulai |
| `end_date` | DATE | Tanggal berakhir |
| `usage_limit` | INTEGER | Batas total penggunaan |
| `usage_count` | INTEGER | Sudah digunakan |
| `is_active` | BOOLEAN | Status aktif |

---

### `expenses` — Pengeluaran

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `category` | expense_category | Kategori pengeluaran |
| `amount` | NUMERIC(12,2) | Jumlah (> 0) |
| `description` | TEXT | Keterangan |
| `expense_date` | DATE | Tanggal pengeluaran |
| `created_by` | UUID | FK ke `profiles` |

---

### `loyalty_members` — Member Loyalty

| Kolom | Tipe | Keterangan |
|-------|------|------------|
| `id` | UUID | Primary key |
| `outlet_id` | UUID | FK ke `outlets` |
| `phone` | TEXT | Nomor HP (identifikasi unik per outlet) |
| `name` | TEXT | Nama member |
| `points` | INTEGER | Poin saat ini |
| `tier` | TEXT | Tier (bronze/silver/gold/platinum) |
| `is_active` | BOOLEAN | Status aktif |

---

## Views (Laporan)

### `v_daily_sales` — Penjualan Harian

```sql
SELECT * FROM v_daily_sales
WHERE outlet_id = '<outlet-id>'
  AND sale_date BETWEEN '2026-05-01' AND '2026-05-27';
```

**Kolom:** `outlet_id`, `sale_date`, `total_orders`, `gross_revenue`, `total_discount`, `total_tax`, `total_service_charge`, `net_revenue`

---

### `v_top_menu_items` — Item Terlaris

```sql
SELECT * FROM v_top_menu_items
WHERE outlet_id = '<outlet-id>'
ORDER BY total_qty DESC
LIMIT 10;
```

**Kolom:** `menu_item_id`, `outlet_id`, `name`, `price`, `category_name`, `total_qty`, `total_revenue`, `order_count`

---

### `v_payment_summary` — Ringkasan Pembayaran

```sql
SELECT * FROM v_payment_summary
WHERE outlet_id = '<outlet-id>'
  AND pay_date >= '2026-05-01';
```

**Kolom:** `outlet_id`, `pay_date`, `method`, `total_transactions`, `total_amount`

---

### `v_low_stock` — Stok Menipis

```sql
SELECT * FROM v_low_stock
WHERE outlet_id = '<outlet-id>'
ORDER BY status;
```

**Kolom:** `ingredient_id`, `outlet_id`, `name`, `unit`, `stock_qty`, `min_stock_qty`, `cost_per_unit`, `status` (out_of_stock / critical / low)

---

### `v_profit_loss` — Laba Rugi Bulanan

**Kolom:** `outlet_id`, `year_month`, `total_revenue`, `total_expense`, `net_profit`

---

### `v_peak_hours` — Jam Sibuk

**Kolom:** `outlet_id`, `hour_of_day`, `order_count`, `revenue`

---

### `v_category_sales` — Penjualan per Kategori

**Kolom:** `outlet_id`, `category_id`, `category_name`, `total_qty`, `total_revenue`

---

## Edge Functions

### Fungsi aktif

Edge Function `generate-qr` sudah dipensiunkan dan tidak lagi tersedia di
server. QR meja dibuat melalui RPC/database flow yang dipakai aplikasi.
Fungsi Edge yang masih aktif adalah `create-staff`, `clock-in`,
`change-device-password`, `change-staff-password`, `archive-orders`, dan
`transaction-archive`. Semua fungsi kecuali `archive-orders` memerlukan JWT;
`archive-orders` memakai secret header khusus dan tidak boleh dipanggil dari
klien publik.

---

### `create-staff`

Membuat akun staff baru dengan invite email.

**Endpoint:**
```
POST https://<project-ref>.supabase.co/functions/v1/create-staff
```

**Request Body:**
```json
{
  "email": "staff@example.com",
  "full_name": "Nama Staff",
  "role": "kasir",
  "outlet_id": "uuid-outlet",
  "phone": "08123456789"
}
```

---

## Row Level Security (RLS)

Semua tabel menggunakan RLS untuk isolasi data antar outlet dan role.

### Prinsip Akses

| Tabel | Owner | Admin/Manajer | Kasir |
|-------|-------|----------------|-------|
| outlets | Semua outlet | Outlet sendiri | Outlet sendiri (read) |
| profiles | Semua | Outlet sendiri | Diri sendiri |
| menu_items | Semua outlet | Outlet sendiri | Read only |
| orders | Semua outlet | Outlet sendiri | Outlet sendiri |
| expenses | Semua outlet | Outlet sendiri | ❌ |

### Fungsi Helper RLS

```sql
auth_role()       -- Mengembalikan role user yang login
auth_outlet_id()  -- Mengembalikan outlet_id user yang login
is_owner()        -- TRUE jika role = 'owner'
```

---

## Enum Types

```sql
-- Role pengguna
user_role: 'owner' | 'admin' | 'manajer' | 'kasir' | 'pelanggan'

-- Status pesanan
order_status: 'draft' | 'confirmed' | 'preparing' | 'ready' | 'served' | 'paid' | 'cancelled' | 'void'

-- Tipe pesanan
order_type: 'dine_in' | 'takeaway' | 'self_order'

-- Metode pembayaran
payment_method: 'cash' | 'qris' | 'debit' | 'credit' | 'ewallet' | 'transfer'

-- Status meja
table_status: 'available' | 'occupied' | 'reserved' | 'dirty'

-- Tipe transaksi stok
stock_transaction_type: 'purchase' | 'usage' | 'adjustment' | 'waste' | 'return'

-- Jenis promo
promo_type: 'percentage' | 'fixed' | 'bundling' | 'bogo'

-- Kategori pengeluaran
expense_category: 'bahan_baku' | 'operasional' | 'gaji' | 'peralatan' | 'marketing' | 'lain_lain'
```

---

## Contoh Query

### Mengambil pesanan aktif hari ini

```javascript
const { data } = await supabase
  .from('orders')
  .select(`
    *,
    restaurant_tables(table_number, area),
    order_items(quantity, unit_price, notes, menu_items(name))
  `)
  .eq('outlet_id', outletId)
  .in('status', ['confirmed', 'preparing', 'ready', 'served'])
  .gte('created_at', new Date().toISOString().split('T')[0])
  .order('created_at', { ascending: false })
```

### Mengambil laporan penjualan

```javascript
const { data } = await supabase
  .from('v_daily_sales')
  .select('*')
  .eq('outlet_id', outletId)
  .gte('sale_date', startDate)
  .lte('sale_date', endDate)
  .order('sale_date', { ascending: true })
```

### Memperbarui status pesanan

```javascript
const { error } = await supabase
  .from('orders')
  .update({ status: 'preparing' })
  .eq('id', orderId)
// Trigger otomatis akan mengurangi stok saat status menjadi 'preparing'
```

### Subscribe realtime pesanan baru

```javascript
supabase
  .channel('orders-realtime')
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'orders',
    filter: `outlet_id=eq.${outletId}`
  }, (payload) => {
    console.log('Pesanan baru:', payload.new)
  })
  .subscribe()
```

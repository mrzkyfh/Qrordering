# Sistem Manajemen Restoran — Dokumentasi Teknis

**Versi:** 1.0.0  
**Terakhir diperbarui:** 27 Mei 2026  
**Platform:** Web (Owner Panel) + Web Mobile (Customer E-Menu)

---

## Panduan pengguna

- [Modul Penggunaan Time420s — PDF](./USER_MANUAL.pdf)
- [Sumber modul — Markdown](./USER_MANUAL.md)

Untuk membuat ulang PDF setelah isi modul diperbarui:

```bash
cd apps/docs
node build-user-manual.mjs
```

---

## Daftar Isi

1. [Gambaran Umum](#gambaran-umum)
2. [Arsitektur Sistem](#arsitektur-sistem)
3. [Persyaratan Sistem](#persyaratan-sistem)
4. [Instalasi & Konfigurasi](#instalasi--konfigurasi)
5. [Struktur Proyek](#struktur-proyek)
6. [Deployment](#deployment)

---

## Gambaran Umum

Sistem ini adalah platform manajemen restoran berbasis cloud yang terdiri dari tiga komponen utama:

| Komponen | Teknologi | Fungsi |
|----------|-----------|--------|
| **Owner Panel** | React 19 + TypeScript + Vite | Dashboard manajemen untuk owner & admin |
| **Customer E-Menu** | Vanilla JS (HTML/CSS/JS) | Menu digital self-order via QR code |
| **Database & Backend** | Supabase (PostgreSQL) | Penyimpanan data, autentikasi, realtime |

### Fitur Utama

- **Multi-outlet** — Satu akun owner dapat mengelola beberapa cabang
- **Manajemen Menu** — Kategori, item, varian, ekstra, harga, foto
- **Self-Order QR** — Pelanggan scan QR meja → pilih menu → kirim pesanan
- **Manajemen Stok** — Bahan baku + resep otomatis potong stok saat order masuk dapur
- **Laporan & Analitik** — Penjualan harian, item terlaris, laba rugi, metode pembayaran
- **Program Loyalty** — Poin member, tier (Bronze/Silver/Gold/Platinum)
- **Manajemen Shift** — Buka/tutup kasir dengan rekonsiliasi kas
- **Promo & Voucher** — Diskon persentase, nominal, bundling, BOGO

---

## Arsitektur Sistem

```
┌─────────────────────────────────────────────────────────────┐
│                        KLIEN                                 │
├──────────────────────────┬──────────────────────────────────┤
│  Owner Panel (Web App)   │  Customer E-Menu (Mobile Web)    │
│  React + TypeScript      │  Vanilla HTML/CSS/JS             │
│  Cloudflare Pages        │  Cloudflare Pages                │
├──────────────────────────┴──────────────────────────────────┤
│                    Supabase                                   │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ PostgreSQL  │  │ Auth (JWT)   │  │ Storage (gambar)  │  │
│  │ + RLS       │  │              │  │                   │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Edge Functions (Deno) — staff, clock-in, archive  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## Persyaratan Sistem

### Untuk Pengembang

| Kebutuhan | Versi Minimum |
|-----------|---------------|
| Node.js | 18.x atau lebih baru |
| npm | 9.x atau lebih baru |
| Supabase CLI | 1.x atau lebih baru |
| Akun Supabase | — |
| Akun Cloudflare | — (untuk deployment) |

### Untuk Pengguna Akhir

- Browser modern (Chrome 90+, Firefox 90+, Safari 14+, Edge 90+)
- Koneksi internet
- Untuk Customer E-Menu: smartphone dengan kamera (untuk scan QR)

---

## Instalasi & Konfigurasi

### 1. Clone Repository

```bash
git clone <repository-url>
cd password
```

### 2. Setup Database (Supabase)

```bash
# Install Supabase CLI
npm install -g supabase

# Login ke Supabase
supabase login

# Hubungkan ke project Supabase Anda
supabase link --project-ref <your-project-ref>

# Jalankan migrasi database secara berurutan
supabase db push
```

Atau jalankan migrasi secara manual melalui Supabase SQL Editor:

```
apps/supabase/migrations/001_types.sql
apps/supabase/migrations/002_tables.sql
apps/supabase/migrations/003_views.sql
apps/supabase/migrations/004_functions_triggers.sql
apps/supabase/migrations/005_rls.sql
apps/supabase/migrations/006_storage.sql
apps/supabase/migrations/007_fix_views.sql
apps/supabase/migrations/008_customer_menu_anon.sql
apps/supabase/migrations/009_inventory_recipes.sql
apps/supabase/migrations/010_category_sales_view.sql
apps/supabase/migrations/011_peak_hours_view.sql
apps/supabase/migrations/012_order_audit_log.sql
apps/supabase/migrations/013_stock_daily_view.sql
apps/supabase/migrations/014_loyalty.sql
```

### 3. Setup Owner Panel

```bash
cd apps/owner-panel

# Install dependencies
npm install

# Buat file environment
cp .env.example .env
```

Isi file `.env`:

```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<your-anon-key>
```

```bash
# Jalankan development server
npm run dev
# Akses di: http://localhost:5173
```

### 4. Setup Customer E-Menu

```bash
cd apps/customer-menu

# Install dependencies
npm install

# Jalankan development server
npm run dev
# Akses di: http://localhost:3001
```

Edit file `app.js` dan sesuaikan variabel konfigurasi Supabase:

```javascript
const SUPABASE_URL = 'https://<project-ref>.supabase.co'
const SUPABASE_ANON_KEY = '<your-anon-key>'
```

---

## Struktur Proyek

```
password/
├── apps/
│   ├── owner-panel/              # Dashboard owner & admin
│   │   ├── src/
│   │   │   ├── pages/
│   │   │   │   ├── auth/         # Halaman login
│   │   │   │   ├── owner/        # Halaman khusus owner
│   │   │   │   └── admin/        # Halaman manajemen outlet
│   │   │   ├── hooks/queries/    # React Query hooks
│   │   │   ├── components/       # Komponen UI reusable
│   │   │   ├── contexts/         # Auth & Outlet context
│   │   │   ├── types/            # TypeScript type definitions
│   │   │   └── lib/              # Utilitas (supabase client, dll)
│   │   └── package.json
│   │
│   ├── customer-menu/            # Aplikasi E-Menu pelanggan
│   │   ├── index.html
│   │   ├── app.js
│   │   └── styles.css
│   │
│   ├── mobile/                   # Aplikasi mobile (Flutter)
│   │
│   └── supabase/
│       └── migrations/           # File migrasi database SQL
│
└── supabase/
    └── functions/                # Supabase Edge Functions
        ├── create-staff/
        ├── clock-in/
        ├── change-device-password/
        ├── change-staff-password/
        ├── archive-orders/
        └── transaction-archive/
```

---

## Deployment

### Owner Panel — Cloudflare Pages

```bash
cd apps/owner-panel

# Build untuk production
npm run build

# Deploy ke Cloudflare Pages
npx wrangler pages deploy dist --project-name=<nama-project>
```

**Environment Variables di Cloudflare Pages:**
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

### Customer E-Menu — Cloudflare Pages

```bash
cd apps/customer-menu

# Deploy ke Cloudflare Pages (static files)
npm run deploy:prod
```

### Supabase Edge Functions

```bash
# Deploy semua functions dari root repository
supabase functions deploy create-staff --workdir apps
supabase functions deploy clock-in --workdir apps
supabase functions deploy change-device-password --workdir apps
supabase functions deploy change-staff-password --workdir apps
supabase functions deploy archive-orders --workdir apps
supabase functions deploy transaction-archive --workdir apps
```

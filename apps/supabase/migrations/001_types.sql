-- ============================================================
-- 001_types.sql
-- Enum types untuk seluruh aplikasi
-- ============================================================

CREATE TYPE user_role AS ENUM (
  'owner', 'admin', 'kasir', 'dapur', 'pelanggan'
);

CREATE TYPE order_status AS ENUM (
  'draft', 'confirmed', 'preparing', 'ready', 'served', 'paid', 'cancelled', 'void'
);

CREATE TYPE order_type AS ENUM (
  'dine_in', 'takeaway', 'self_order'
);

CREATE TYPE payment_method AS ENUM (
  'cash', 'qris', 'debit', 'credit', 'ewallet', 'transfer'
);

CREATE TYPE table_status AS ENUM (
  'available', 'occupied', 'reserved', 'dirty'
);

CREATE TYPE stock_transaction_type AS ENUM (
  'purchase', 'usage', 'adjustment', 'waste', 'return'
);

CREATE TYPE promo_type AS ENUM (
  'percentage', 'fixed', 'bundling', 'bogo'
);

CREATE TYPE expense_category AS ENUM (
  'bahan_baku', 'operasional', 'gaji', 'peralatan', 'marketing', 'lain_lain'
);

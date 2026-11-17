-- ============================================================
-- 002_tables.sql
-- Semua tabel utama aplikasi panel restoran
-- ============================================================

-- ── Outlets ─────────────────────────────────────────────────
CREATE TABLE outlets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  address       TEXT,
  phone         TEXT,
  city          TEXT,
  logo_url      TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  settings      JSONB NOT NULL DEFAULT '{
    "tax_percent": 11,
    "service_charge_percent": 5,
    "currency": "IDR",
    "receipt_footer": "Terima kasih telah berkunjung!"
  }'::JSONB,
  loyalty_settings JSONB DEFAULT '{
    "points_per_rupiah": 1,
    "redeem_rate": 100,
    "tier_threshold": {}
  }'::JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Profiles ─────────────────────────────────────────────────
-- Extends auth.users — dibuat otomatis via trigger saat signup
CREATE TABLE profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  outlet_id     UUID REFERENCES outlets(id) ON DELETE SET NULL,
  role          user_role NOT NULL DEFAULT 'kasir',
  full_name     TEXT NOT NULL DEFAULT '',
  phone         TEXT,
  avatar_url    TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Restaurant Tables ────────────────────────────────────────
CREATE TABLE restaurant_tables (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id       UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  table_number    TEXT NOT NULL,
  area            TEXT,
  capacity        INTEGER NOT NULL DEFAULT 4,
  status          table_status NOT NULL DEFAULT 'available',
  qr_token        TEXT UNIQUE,
  qr_code_url     TEXT,
  qr_generated_at TIMESTAMPTZ,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE(outlet_id, table_number)
);

-- ── Menu Categories ──────────────────────────────────────────
CREATE TABLE menu_categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  icon       TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

-- ── Menu Items ───────────────────────────────────────────────
CREATE TABLE menu_items (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id        UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  category_id      UUID REFERENCES menu_categories(id) ON DELETE SET NULL,
  name             TEXT NOT NULL,
  description      TEXT,
  price            NUMERIC(12,2) NOT NULL CHECK (price >= 0),
  image_url        TEXT,
  is_available     BOOLEAN NOT NULL DEFAULT TRUE,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  is_featured      BOOLEAN NOT NULL DEFAULT FALSE,
  preparation_time INTEGER,
  tags             TEXT[],
  variants         JSONB,
  sort_order       INTEGER NOT NULL DEFAULT 0
);

-- ── Shifts (Sesi Kasir) ──────────────────────────────────────
CREATE TABLE shifts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id     UUID NOT NULL REFERENCES outlets(id),
  kasir_id      UUID NOT NULL REFERENCES profiles(id),
  start_time    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  end_time      TIMESTAMPTZ,
  opening_cash  NUMERIC(12,2) NOT NULL DEFAULT 0,
  closing_cash  NUMERIC(12,2),
  expected_cash NUMERIC(12,2),
  cash_difference NUMERIC(12,2),
  notes         TEXT
);

-- ── Orders ───────────────────────────────────────────────────
CREATE TABLE orders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id       UUID NOT NULL REFERENCES outlets(id),
  shift_id        UUID REFERENCES shifts(id) ON DELETE SET NULL,
  table_id        UUID REFERENCES restaurant_tables(id) ON DELETE SET NULL,
  order_number    TEXT NOT NULL,
  order_type      order_type NOT NULL DEFAULT 'dine_in',
  status          order_status NOT NULL DEFAULT 'draft',
  customer_name   TEXT,
  subtotal        NUMERIC(12,2) NOT NULL DEFAULT 0,
  discount_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  service_charge  NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_by      UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(outlet_id, order_number)
);

-- ── Order Items ──────────────────────────────────────────────
CREATE TABLE order_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  menu_item_id UUID NOT NULL REFERENCES menu_items(id),
  quantity     INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price   NUMERIC(12,2) NOT NULL,
  subtotal     NUMERIC(12,2) NOT NULL,
  notes        TEXT
);

-- ── Payments ─────────────────────────────────────────────────
CREATE TABLE payments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  outlet_id        UUID NOT NULL REFERENCES outlets(id),
  method           payment_method NOT NULL,
  amount           NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  reference_number TEXT,
  paid_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Ingredients (Bahan Baku) ─────────────────────────────────
CREATE TABLE ingredients (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id     UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  unit          TEXT NOT NULL,
  cost_per_unit NUMERIC(12,2) NOT NULL DEFAULT 0,
  stock_qty     NUMERIC(10,3) NOT NULL DEFAULT 0,
  min_stock_qty NUMERIC(10,3) NOT NULL DEFAULT 0,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Stock Transactions ───────────────────────────────────────
CREATE TABLE stock_transactions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id     UUID NOT NULL REFERENCES outlets(id),
  ingredient_id UUID NOT NULL REFERENCES ingredients(id),
  type          stock_transaction_type NOT NULL,
  qty_before    NUMERIC(10,3) NOT NULL,
  qty           NUMERIC(10,3) NOT NULL CHECK (qty > 0),
  qty_after     NUMERIC(10,3) NOT NULL,
  cost_per_unit NUMERIC(12,2),
  notes         TEXT,
  created_by    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Promos ───────────────────────────────────────────────────
CREATE TABLE promos (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id   UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  description TEXT,
  type        promo_type NOT NULL,
  value       NUMERIC(12,2) NOT NULL CHECK (value >= 0),
  min_order   NUMERIC(12,2) NOT NULL DEFAULT 0,
  max_discount NUMERIC(12,2),
  start_date  DATE,
  end_date    DATE,
  usage_limit INTEGER,
  usage_count INTEGER NOT NULL DEFAULT 0,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Vouchers ─────────────────────────────────────────────────
CREATE TABLE vouchers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_id    UUID NOT NULL REFERENCES promos(id) ON DELETE CASCADE,
  outlet_id   UUID NOT NULL REFERENCES outlets(id),
  code        TEXT NOT NULL UNIQUE,
  usage_limit INTEGER,
  usage_count INTEGER NOT NULL DEFAULT 0,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Expenses (Pengeluaran) ───────────────────────────────────
CREATE TABLE expenses (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id    UUID NOT NULL REFERENCES outlets(id),
  category     expense_category NOT NULL,
  amount       NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  description  TEXT,
  expense_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_by   UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes untuk performa query ─────────────────────────────
CREATE INDEX idx_orders_outlet_created  ON orders(outlet_id, created_at DESC);
CREATE INDEX idx_orders_status          ON orders(outlet_id, status);
CREATE INDEX idx_order_items_order      ON order_items(order_id);
CREATE INDEX idx_payments_outlet        ON payments(outlet_id, paid_at DESC);
CREATE INDEX idx_menu_items_outlet_cat  ON menu_items(outlet_id, category_id);
CREATE INDEX idx_stock_tx_outlet        ON stock_transactions(outlet_id, created_at DESC);
CREATE INDEX idx_ingredients_outlet     ON ingredients(outlet_id);
CREATE INDEX idx_profiles_outlet        ON profiles(outlet_id);

-- ============================================================
-- 004_functions_triggers.sql
-- Functions dan triggers otomatis
-- ============================================================

-- ── Helper: update updated_at ────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Apply ke semua tabel yang punya kolom updated_at
CREATE TRIGGER trg_outlets_updated_at
  BEFORE UPDATE ON outlets
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_menu_items_updated_at
  BEFORE UPDATE ON menu_items
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_ingredients_updated_at
  BEFORE UPDATE ON ingredients
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_promos_updated_at
  BEFORE UPDATE ON promos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── Auto-create profile saat user baru signup ────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO profiles (id, full_name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'kasir')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── Update last_login_at saat user login ─────────────────────
CREATE OR REPLACE FUNCTION handle_user_login()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Supabase update last_sign_in_at di auth.users saat login
  -- Kita sync ke profiles.last_login_at
  UPDATE profiles
  SET last_login_at = NOW()
  WHERE id = NEW.id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_on_auth_user_login
  AFTER UPDATE OF last_sign_in_at ON auth.users
  FOR EACH ROW
  WHEN (OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at)
  EXECUTE FUNCTION handle_user_login();

-- ── Auto-generate order number ───────────────────────────────
CREATE OR REPLACE FUNCTION generate_order_number(p_outlet_id UUID)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_date    TEXT := TO_CHAR(NOW() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD');
  v_count   INTEGER;
  v_number  TEXT;
BEGIN
  SELECT COUNT(*) + 1 INTO v_count
  FROM orders
  WHERE outlet_id = p_outlet_id
    AND DATE(created_at AT TIME ZONE 'Asia/Jakarta') = CURRENT_DATE;

  v_number := 'ORD-' || v_date || '-' || LPAD(v_count::TEXT, 4, '0');
  RETURN v_number;
END;
$$;

-- ── Update tabel status otomatis saat order berubah ──────────
CREATE OR REPLACE FUNCTION sync_table_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Saat order confirmed/preparing/ready/served → meja = occupied
  IF NEW.table_id IS NOT NULL AND NEW.status IN ('confirmed', 'preparing', 'ready', 'served') THEN
    UPDATE restaurant_tables SET status = 'occupied' WHERE id = NEW.table_id;
  END IF;

  -- Saat order paid/cancelled/void → cek apakah ada order aktif lain di meja itu
  IF NEW.table_id IS NOT NULL AND NEW.status IN ('paid', 'cancelled', 'void') THEN
    IF NOT EXISTS (
      SELECT 1 FROM orders
      WHERE table_id = NEW.table_id
        AND id <> NEW.id
        AND status IN ('confirmed', 'preparing', 'ready', 'served')
    ) THEN
      UPDATE restaurant_tables SET status = 'available' WHERE id = NEW.table_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_table_status
  AFTER UPDATE OF status ON orders
  FOR EACH ROW EXECUTE FUNCTION sync_table_status();

-- ── Update ingredient stock saat stock_transaction insert ─────
CREATE OR REPLACE FUNCTION apply_stock_transaction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type IN ('purchase', 'return', 'adjustment') THEN
    UPDATE ingredients
    SET stock_qty  = stock_qty + NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  ELSIF NEW.type IN ('usage', 'waste') THEN
    UPDATE ingredients
    SET stock_qty  = GREATEST(stock_qty - NEW.qty, 0),
        updated_at = NOW()
    WHERE id = NEW.ingredient_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_stock_transaction
  AFTER INSERT ON stock_transactions
  FOR EACH ROW EXECUTE FUNCTION apply_stock_transaction();

-- ── Increment promo usage_count saat order dibuat ────────────
-- (dipanggil manual dari aplikasi atau bisa ditambah trigger via junction table)
-- Fungsi helper untuk dipakai dari aplikasi
CREATE OR REPLACE FUNCTION increment_promo_usage(p_promo_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  UPDATE promos
  SET usage_count = usage_count + 1,
      updated_at  = NOW()
  WHERE id = p_promo_id;
END;
$$;

-- 131_order_rounding_authoritative.sql
-- Pembulatan total harus menjadi bagian dari snapshot transaksi, bukan hanya
-- tampilan mobile. Dengan begitu POS online, offline replay, dan self-order
-- menyimpan total yang sama walau setting outlet berubah setelah transaksi.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS rounding INTEGER;

COMMENT ON COLUMN public.orders.rounding IS
  'Snapshot nominal pembulatan total: 0/NULL = tanpa pembulatan, 100/500/1000 '
  '= dibulatkan ke nominal terdekat.';

CREATE OR REPLACE FUNCTION public.enforce_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_base NUMERIC;
  v_rounding INTEGER;
BEGIN
  -- Snapshot tax_inclusive dan rounding hanya saat order baru dibuat. Order
  -- historis/offline tidak boleh dihitung ulang menggunakan setting terbaru.
  IF TG_OP = 'INSERT' AND NEW.tax_inclusive IS NULL THEN
    SELECT COALESCE((settings->>'tax_inclusive')::boolean, false)
      INTO NEW.tax_inclusive
      FROM outlets WHERE id = NEW.outlet_id;
    NEW.tax_inclusive := COALESCE(NEW.tax_inclusive, false);
  END IF;

  IF TG_OP = 'INSERT' AND NEW.rounding IS NULL THEN
    SELECT COALESCE((settings->>'rounding')::integer, 0)
      INTO NEW.rounding
      FROM outlets WHERE id = NEW.outlet_id;
  END IF;

  NEW.rounding := CASE
    WHEN NEW.rounding IN (100, 500, 1000) THEN NEW.rounding
    ELSE 0
  END;

  v_base := GREATEST(0, COALESCE(NEW.subtotal, 0)
                        - COALESCE(NEW.discount_amount, 0)
                        - COALESCE(NEW.loyalty_discount, 0))
            + CASE WHEN COALESCE(NEW.tax_inclusive, false)
                   THEN 0 ELSE COALESCE(NEW.tax_amount, 0) END
            + COALESCE(NEW.service_charge, 0);

  NEW.total_amount := CASE
    WHEN NEW.rounding > 0 THEN round(v_base / NEW.rounding) * NEW.rounding
    ELSE v_base
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_order_total ON public.orders;
CREATE TRIGGER trg_enforce_order_total
  BEFORE INSERT OR UPDATE OF
    subtotal, discount_amount, loyalty_discount,
    tax_amount, service_charge, tax_inclusive, rounding, total_amount
  ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_order_total();

-- Customer menu perlu melihat pembulatan yang sama agar quote di keranjang
-- identik dengan total yang disimpan server. View tetap hanya mengekspos field
-- setting yang aman untuk publik.
CREATE OR REPLACE VIEW public.v_outlets_public AS
SELECT
  o.id,
  o.name,
  o.address,
  o.phone,
  o.city,
  o.logo_url,
  o.is_active,
  jsonb_build_object(
    'tax_percent',          o.settings->'tax_percent',
    'tax_active',           o.settings->'tax_active',
    'tax_name',             o.settings->'tax_name',
    'tax_inclusive',        o.settings->'tax_inclusive',
    'tax_calculation',      o.settings->'tax_calculation',
    'tax_order_types',       o.settings->'tax_order_types',
    'taxes',                 o.settings->'taxes',
    'service_charge_percent', o.settings->'service_charge_percent',
    'currency',             o.settings->'currency',
    'receipt_footer',       o.settings->'receipt_footer',
    'rounding',             o.settings->'rounding',
    'self_order_enabled',   COALESCE(o.settings->'self_order_enabled', 'true'::jsonb)
  ) AS settings,
  o.created_at,
  o.updated_at
FROM public.outlets o
WHERE o.is_active = true;

GRANT SELECT ON public.v_outlets_public TO anon, authenticated;

COMMENT ON VIEW public.v_outlets_public IS
  'Public-safe outlet projection for customer menu: tax, service, rounding, '
  'and self-order availability only.';

-- POS menghitung pajak di mobile sebelum order dibuat. Self-order dihitung di
-- RPC lama (129), sehingga policy tipe order/kalkulasi perlu ditegakkan ulang
-- di server setelah header masuk. Trigger UPDATE berikut memicu kembali
-- enforce_order_total dan tidak menerima nominal pajak dari klien.
CREATE OR REPLACE FUNCTION public.enforce_self_order_tax_policy()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_tax_rules JSONB;
  v_tax_cfg JSONB;
  v_pct NUMERIC := 0;
  v_active BOOLEAN := true;
  v_inclusive BOOLEAN := false;
  v_calculation TEXT := 'before_discount';
  v_order_types JSONB;
  v_base NUMERIC;
  v_tax NUMERIC := 0;
  v_has_inclusive BOOLEAN := false;
  v_has_exclusive BOOLEAN := false;
BEGIN
  IF NEW.order_type <> 'self_order' THEN RETURN NEW; END IF;

  SELECT settings INTO v_settings FROM outlets WHERE id = NEW.outlet_id;
  v_tax_rules := v_settings->'taxes';
  IF jsonb_typeof(v_tax_rules) = 'array'
     AND jsonb_array_length(v_tax_rules) > 0 THEN
    FOR v_tax_cfg IN SELECT value FROM jsonb_array_elements(v_tax_rules) LOOP
      v_pct := COALESCE((v_tax_cfg->>'percent')::numeric, 0);
      v_active := COALESCE((v_tax_cfg->>'active')::boolean, true);
      v_inclusive := COALESCE((v_tax_cfg->>'inclusive')::boolean, false);
      v_calculation := COALESCE(v_tax_cfg->>'calculation', 'before_discount');
      v_order_types := v_tax_cfg->'order_types';

      IF jsonb_typeof(v_order_types) = 'array'
         AND jsonb_array_length(v_order_types) > 0
         AND NOT (v_order_types ? 'self_order') THEN
        v_active := false;
      END IF;

      v_base := CASE WHEN v_calculation = 'after_discount'
        THEN GREATEST(COALESCE(NEW.subtotal, 0)
                      - COALESCE(NEW.discount_amount, 0)
                      - COALESCE(NEW.loyalty_discount, 0), 0)
        ELSE COALESCE(NEW.subtotal, 0)
      END;

      IF v_active AND v_pct > 0 THEN
        v_tax := v_tax + CASE WHEN v_inclusive
          THEN round(v_base - v_base / (1 + v_pct / 100))
          ELSE round(v_base * v_pct / 100)
        END;
        IF v_inclusive THEN
          v_has_inclusive := true;
        ELSE
          v_has_exclusive := true;
        END IF;
      END IF;
    END LOOP;
  ELSE
    -- Kompatibilitas dengan outlet lama yang masih memakai field legacy.
    v_active := COALESCE((v_settings->>'tax_active')::boolean, true);
    v_pct := COALESCE((v_settings->>'tax_percent')::numeric, 0);
    v_inclusive := COALESCE((v_settings->>'tax_inclusive')::boolean, false);
    v_calculation := COALESCE(v_settings->>'tax_calculation', 'before_discount');
    v_order_types := v_settings->'tax_order_types';
    IF jsonb_typeof(v_order_types) = 'array'
       AND jsonb_array_length(v_order_types) > 0
       AND NOT (v_order_types ? 'self_order') THEN
      v_active := false;
    END IF;

    v_base := CASE WHEN v_calculation = 'after_discount'
      THEN GREATEST(COALESCE(NEW.subtotal, 0)
                    - COALESCE(NEW.discount_amount, 0)
                    - COALESCE(NEW.loyalty_discount, 0), 0)
      ELSE COALESCE(NEW.subtotal, 0)
    END;

    IF v_active AND v_pct > 0 THEN
      v_tax := CASE WHEN v_inclusive
        THEN round(v_base - v_base / (1 + v_pct / 100))
        ELSE round(v_base * v_pct / 100)
      END;
      IF v_inclusive THEN
        v_has_inclusive := true;
      ELSE
        v_has_exclusive := true;
      END IF;
    END IF;
  END IF;

  -- Kolom order hanya punya satu flag inclusive. Mode campuran dinormalisasi
  -- sebagai exclusive supaya seluruh pajak tetap masuk ke total.
  v_inclusive := v_has_inclusive AND NOT v_has_exclusive;

  IF COALESCE(NEW.tax_amount, 0) <> v_tax
     OR COALESCE(NEW.tax_inclusive, false) <> v_inclusive THEN
    UPDATE orders
       SET tax_amount = v_tax,
           tax_inclusive = v_inclusive
     WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_self_order_tax_policy ON public.orders;
CREATE TRIGGER trg_enforce_self_order_tax_policy
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_self_order_tax_policy();

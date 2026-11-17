-- 158_archive_integrity_reporting.sql
-- Menutup celah arsip 90 hari:
--   * kunci ringkasan memakai ID stabil, bukan nama yang dapat sama;
--   * tanggal pembayaran/refund mengikuti waktu kejadian sebenarnya;
--   * laporan shift, pelanggan, HPP, dan pembayaran membaca data aktif + arsip;
--   * daftar transaksi melakukan pagination sebelum menyusun detail JSON;
--   * setiap eksekusi arsip mempunyai log yang bertahan di database.

-- ── 1. Kunci ringkasan yang tidak bertabrakan saat nama sama ────────────────
ALTER TABLE public.archived_item_sales_daily
  ADD COLUMN IF NOT EXISTS item_key TEXT;

UPDATE public.archived_item_sales_daily
SET item_key = COALESCE(menu_item_id::TEXT, 'deleted:' || md5(menu_name))
WHERE item_key IS NULL;

ALTER TABLE public.archived_item_sales_daily
  ALTER COLUMN item_key SET NOT NULL,
  DROP CONSTRAINT IF EXISTS archived_item_sales_daily_pkey,
  ADD CONSTRAINT archived_item_sales_daily_pkey
    PRIMARY KEY (outlet_id, sales_date, item_key);

ALTER TABLE public.archived_extra_sales_daily
  ADD COLUMN IF NOT EXISTS option_key TEXT;

UPDATE public.archived_extra_sales_daily
SET option_key = COALESCE(option_id::TEXT, 'deleted:' || md5(COALESCE(extra_name, '') || ':' || option_name))
WHERE option_key IS NULL;

ALTER TABLE public.archived_extra_sales_daily
  ALTER COLUMN option_key SET NOT NULL,
  DROP CONSTRAINT IF EXISTS archived_extra_sales_daily_pkey,
  ADD CONSTRAINT archived_extra_sales_daily_pkey
    PRIMARY KEY (outlet_id, sales_date, option_key);

ALTER TABLE public.archived_cashier_sales_daily
  ADD COLUMN IF NOT EXISTS cashier_key TEXT;

UPDATE public.archived_cashier_sales_daily
SET cashier_key = COALESCE(kasir_id::TEXT, 'deleted:' || md5(kasir_name))
WHERE cashier_key IS NULL;

ALTER TABLE public.archived_cashier_sales_daily
  ALTER COLUMN cashier_key SET NOT NULL,
  DROP CONSTRAINT IF EXISTS archived_cashier_sales_daily_pkey,
  ADD CONSTRAINT archived_cashier_sales_daily_pkey
    PRIMARY KEY (outlet_id, work_date, cashier_key);

-- Satu tanggal order dapat memiliki pembayaran pada tanggal yang berbeda.
-- source_order_date mencegah ringkasan kandidat arsip lain saling menimpa.
ALTER TABLE public.archived_payment_sales_daily
  ADD COLUMN IF NOT EXISTS source_order_date DATE;

UPDATE public.archived_payment_sales_daily
SET source_order_date = pay_date
WHERE source_order_date IS NULL;

ALTER TABLE public.archived_payment_sales_daily
  ALTER COLUMN source_order_date SET NOT NULL,
  DROP CONSTRAINT IF EXISTS archived_payment_sales_daily_pkey,
  ADD CONSTRAINT archived_payment_sales_daily_pkey
    PRIMARY KEY (outlet_id, source_order_date, pay_date, method);

CREATE TABLE IF NOT EXISTS public.archived_refund_sales_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  source_order_date DATE NOT NULL,
  refund_date DATE NOT NULL,
  method public.payment_method NOT NULL,
  total_refunds BIGINT NOT NULL DEFAULT 0,
  total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, source_order_date, refund_date, method)
);

ALTER TABLE public.archived_refund_sales_daily ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS archived_refund_sales_daily_select
  ON public.archived_refund_sales_daily;
CREATE POLICY archived_refund_sales_daily_select
  ON public.archived_refund_sales_daily
  FOR SELECT TO authenticated
  USING (public.is_owner() OR outlet_id = public.auth_outlet_id());
GRANT SELECT ON public.archived_refund_sales_daily TO authenticated;

-- Indeks pencarian dan relasi yang dipakai berulang oleh proses arsip.
CREATE INDEX IF NOT EXISTS idx_payments_order
  ON public.payments(order_id);
CREATE INDEX IF NOT EXISTS idx_promo_usages_order
  ON public.promo_usages(order_id);

-- ── 2. Indeks transaksi arsip menyimpan data laporan yang masih dibutuhkan ──
ALTER TABLE public.transaction_archive_orders
  ADD COLUMN IF NOT EXISTS loyalty_member_id UUID,
  ADD COLUMN IF NOT EXISTS refunds JSONB NOT NULL DEFAULT '[]'::JSONB,
  ADD COLUMN IF NOT EXISTS promo_usages JSONB NOT NULL DEFAULT '[]'::JSONB;

CREATE INDEX IF NOT EXISTS idx_archive_orders_loyalty_created
  ON public.transaction_archive_orders(loyalty_member_id, created_at DESC)
  WHERE loyalty_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_archive_orders_shift
  ON public.transaction_archive_orders(shift_id)
  WHERE shift_id IS NOT NULL;

-- ── 3. Log proses arsip yang tidak hilang bersama log platform 1 hari ────────
CREATE TABLE IF NOT EXISTS public.transaction_archive_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'completed', 'partial', 'failed')),
  keep_days INTEGER NOT NULL,
  candidate_limit INTEGER NOT NULL,
  candidate_count INTEGER NOT NULL DEFAULT 0,
  archived_count INTEGER NOT NULL DEFAULT 0,
  archived_order_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  failures JSONB NOT NULL DEFAULT '[]'::JSONB,
  invoked_by TEXT NOT NULL DEFAULT 'cron'
    CHECK (invoked_by IN ('cron', 'manual', 'test'))
);

ALTER TABLE public.transaction_archive_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS transaction_archive_runs_select
  ON public.transaction_archive_runs;
CREATE POLICY transaction_archive_runs_select
  ON public.transaction_archive_runs
  FOR SELECT TO authenticated
  USING (public.is_owner());
GRANT SELECT ON public.transaction_archive_runs TO authenticated;

CREATE INDEX IF NOT EXISTS idx_archive_runs_started
  ON public.transaction_archive_runs(started_at DESC);

-- ── 4. Finalisasi arsip dengan ringkasan yang aman ──────────────────────────
CREATE OR REPLACE FUNCTION public.finalize_transaction_archive(
  p_outlet_id UUID,
  p_business_date DATE,
  p_storage_path TEXT,
  p_checksum_sha256 TEXT,
  p_order_count INTEGER,
  p_total_amount NUMERIC,
  p_compressed_bytes BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_from TIMESTAMPTZ := p_business_date::TIMESTAMP AT TIME ZONE 'Asia/Jakarta';
  v_to TIMESTAMPTZ := (p_business_date + 1)::TIMESTAMP AT TIME ZONE 'Asia/Jakarta';
  v_count INTEGER;
  v_total NUMERIC(14,2);
BEGIN
  IF p_business_date >= public.jkt_today() - 90 THEN
    RAISE EXCEPTION 'Tanggal belum melewati retensi 90 hari';
  END IF;
  IF p_storage_path IS NULL OR p_checksum_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Metadata arsip tidak valid';
  END IF;

  -- Mengunci header order. Proses pembayaran/refund resmi juga mengunci order,
  -- sehingga data tidak dapat berubah di tengah finalisasi.
  PERFORM 1
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  FOR UPDATE;

  SELECT COUNT(*)::INTEGER, COALESCE(SUM(o.total_amount), 0)::NUMERIC(14,2)
  INTO v_count, v_total
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id
    AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to;

  IF v_count = 0 OR v_count <> p_order_count OR v_total <> p_total_amount THEN
    RAISE EXCEPTION 'Isi database berubah setelah file arsip dibuat';
  END IF;

  INSERT INTO public.sales_daily_summary AS s (
    outlet_id, sales_date, order_count, gross, discount, tax, service, net,
    refund, cogs, by_payment, by_category, by_staff, refreshed_at
  )
  SELECT
    p_outlet_id,
    p_business_date,
    COUNT(*)::INTEGER,
    COALESCE(SUM(o.subtotal), 0),
    COALESCE(SUM(o.discount_amount), 0),
    COALESCE(SUM(o.tax_amount), 0),
    COALESCE(SUM(o.service_charge), 0),
    COALESCE(SUM(o.total_amount - COALESCE(r.refund, 0)), 0),
    COALESCE(SUM(COALESCE(r.refund, 0)), 0),
    COALESCE(SUM(o.cogs_amount), 0),
    COALESCE((
      SELECT jsonb_object_agg(x.method, x.amount)
      FROM (
        SELECT pay.method::TEXT AS method, SUM(pay.amount)::NUMERIC AS amount
        FROM public.payments pay
        JOIN public.orders op ON op.id = pay.order_id
        WHERE op.outlet_id = p_outlet_id AND op.status = 'paid'
          AND op.created_at >= v_from AND op.created_at < v_to
        GROUP BY pay.method
      ) x
    ), '{}'::JSONB),
    COALESCE((
      SELECT jsonb_object_agg(x.category_id, x.revenue)
      FROM (
        SELECT mi.category_id::TEXT AS category_id,
          SUM(oi.subtotal - COALESCE(oi.refunded_qty, 0) * oi.unit_price)::NUMERIC AS revenue
        FROM public.order_items oi
        JOIN public.orders op ON op.id = oi.order_id
        JOIN public.menu_items mi ON mi.id = oi.menu_item_id
        WHERE op.outlet_id = p_outlet_id AND op.status = 'paid'
          AND op.created_at >= v_from AND op.created_at < v_to
          AND mi.category_id IS NOT NULL
        GROUP BY mi.category_id
      ) x
    ), '{}'::JSONB),
    COALESCE((
      SELECT jsonb_object_agg(x.staff_id, x.revenue)
      FROM (
        SELECT op.created_by::TEXT AS staff_id,
          SUM(op.total_amount - COALESCE(rr.refund, 0))::NUMERIC AS revenue
        FROM public.orders op
        LEFT JOIN (
          SELECT order_id, SUM(amount) AS refund
          FROM public.refunds
          GROUP BY order_id
        ) rr ON rr.order_id = op.id
        WHERE op.outlet_id = p_outlet_id AND op.status = 'paid'
          AND op.created_at >= v_from AND op.created_at < v_to
          AND op.created_by IS NOT NULL
        GROUP BY op.created_by
      ) x
    ), '{}'::JSONB),
    now()
  FROM public.orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund
    FROM public.refunds
    GROUP BY order_id
  ) r ON r.order_id = o.id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY o.outlet_id
  ON CONFLICT (outlet_id, sales_date) DO UPDATE SET
    order_count = EXCLUDED.order_count,
    gross = EXCLUDED.gross,
    discount = EXCLUDED.discount,
    tax = EXCLUDED.tax,
    service = EXCLUDED.service,
    net = EXCLUDED.net,
    refund = EXCLUDED.refund,
    cogs = EXCLUDED.cogs,
    by_payment = EXCLUDED.by_payment,
    by_category = EXCLUDED.by_category,
    by_staff = EXCLUDED.by_staff,
    refreshed_at = now();

  INSERT INTO public.archived_item_sales_daily AS a (
    outlet_id, sales_date, item_key, menu_item_id, menu_name, price,
    category_id, category_name, department_id, department_name, department_color,
    qty_sold, total_revenue, order_count
  )
  SELECT
    p_outlet_id,
    p_business_date,
    COALESCE(oi.menu_item_id::TEXT, 'deleted:' || md5(COALESCE(mi.name, 'Menu dihapus'))),
    oi.menu_item_id,
    COALESCE(mi.name, 'Menu dihapus'),
    MAX(oi.unit_price),
    mc.id, mc.name, md.id, md.name, md.color,
    SUM(oi.quantity - COALESCE(oi.refunded_qty, 0))::BIGINT,
    SUM(oi.subtotal - COALESCE(oi.refunded_qty, 0) * oi.unit_price),
    COUNT(DISTINCT o.id)::BIGINT
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
  LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
  LEFT JOIN public.menu_departments md ON md.id = mc.department_id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY oi.menu_item_id, COALESCE(mi.name, 'Menu dihapus'),
    mc.id, mc.name, md.id, md.name, md.color
  ON CONFLICT (outlet_id, sales_date, item_key) DO UPDATE SET
    menu_item_id = EXCLUDED.menu_item_id,
    menu_name = EXCLUDED.menu_name,
    price = EXCLUDED.price,
    category_id = EXCLUDED.category_id,
    category_name = EXCLUDED.category_name,
    department_id = EXCLUDED.department_id,
    department_name = EXCLUDED.department_name,
    department_color = EXCLUDED.department_color,
    qty_sold = EXCLUDED.qty_sold,
    total_revenue = EXCLUDED.total_revenue,
    order_count = EXCLUDED.order_count;

  INSERT INTO public.archived_extra_sales_daily AS a (
    outlet_id, sales_date, option_key, extra_id, extra_name, option_id,
    option_name, option_price, qty_selected, total_revenue
  )
  SELECT
    p_outlet_id,
    p_business_date,
    COALESCE(
      oio.menu_extra_option_id::TEXT,
      'deleted:' || md5(COALESCE(oio.extra_name, '') || ':' || COALESCE(oio.option_name, 'Tambahan dihapus'))
    ),
    MIN(oio.menu_extra_id),
    MIN(oio.extra_name),
    oio.menu_extra_option_id,
    COALESCE(oio.option_name, 'Tambahan dihapus'),
    MAX(oio.price),
    COUNT(oio.id)::BIGINT,
    COALESCE(SUM(oio.price * (oi.quantity - COALESCE(oi.refunded_qty, 0))), 0)
  FROM public.order_item_options oio
  JOIN public.order_items oi ON oi.id = oio.order_item_id
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY oio.menu_extra_option_id,
    COALESCE(oio.extra_name, ''),
    COALESCE(oio.option_name, 'Tambahan dihapus')
  ON CONFLICT (outlet_id, sales_date, option_key) DO UPDATE SET
    extra_id = EXCLUDED.extra_id,
    extra_name = EXCLUDED.extra_name,
    option_id = EXCLUDED.option_id,
    option_name = EXCLUDED.option_name,
    option_price = EXCLUDED.option_price,
    qty_selected = EXCLUDED.qty_selected,
    total_revenue = EXCLUDED.total_revenue;

  -- Pembayaran memakai paid_at; refund memakai created_at. source_order_date
  -- menjaga beberapa kandidat arsip tidak saling menimpa.
  INSERT INTO public.archived_payment_sales_daily AS a (
    outlet_id, source_order_date, pay_date, method,
    total_transactions, total_amount
  )
  SELECT
    p_outlet_id,
    p_business_date,
    (pay.paid_at AT TIME ZONE 'Asia/Jakarta')::DATE,
    pay.method,
    COUNT(*)::BIGINT,
    SUM(pay.amount)::NUMERIC
  FROM public.payments pay
  JOIN public.orders o ON o.id = pay.order_id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY (pay.paid_at AT TIME ZONE 'Asia/Jakarta')::DATE, pay.method
  ON CONFLICT (outlet_id, source_order_date, pay_date, method) DO UPDATE SET
    total_transactions = EXCLUDED.total_transactions,
    total_amount = EXCLUDED.total_amount;

  INSERT INTO public.archived_refund_sales_daily AS a (
    outlet_id, source_order_date, refund_date, method,
    total_refunds, total_amount
  )
  SELECT
    p_outlet_id,
    p_business_date,
    (r.created_at AT TIME ZONE 'Asia/Jakarta')::DATE,
    r.method,
    COUNT(*)::BIGINT,
    SUM(r.amount)::NUMERIC
  FROM public.refunds r
  JOIN public.orders o ON o.id = r.order_id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY (r.created_at AT TIME ZONE 'Asia/Jakarta')::DATE, r.method
  ON CONFLICT (outlet_id, source_order_date, refund_date, method) DO UPDATE SET
    total_refunds = EXCLUDED.total_refunds,
    total_amount = EXCLUDED.total_amount;

  INSERT INTO public.archived_cashier_sales_daily AS a (
    outlet_id, work_date, cashier_key, kasir_id, kasir_name, total_orders,
    total_revenue, total_discount_given
  )
  SELECT
    p_outlet_id,
    p_business_date,
    o.created_by::TEXT,
    o.created_by,
    COALESCE(p.full_name, 'Pengguna dihapus'),
    COUNT(*)::BIGINT,
    SUM(o.total_amount - COALESCE(r.refund, 0)),
    SUM(o.discount_amount)
  FROM public.orders o
  LEFT JOIN public.profiles p ON p.id = o.created_by
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund
    FROM public.refunds
    GROUP BY order_id
  ) r ON r.order_id = o.id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
    AND o.created_by IS NOT NULL
  GROUP BY o.created_by, COALESCE(p.full_name, 'Pengguna dihapus')
  ON CONFLICT (outlet_id, work_date, cashier_key) DO UPDATE SET
    kasir_id = EXCLUDED.kasir_id,
    kasir_name = EXCLUDED.kasir_name,
    total_orders = EXCLUDED.total_orders,
    total_revenue = EXCLUDED.total_revenue,
    total_discount_given = EXCLUDED.total_discount_given;

  INSERT INTO public.archived_peak_hours_daily AS a (
    outlet_id, sale_date, hour_of_day, total_orders, total_revenue
  )
  SELECT
    p_outlet_id,
    p_business_date,
    EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER,
    COUNT(*)::INTEGER,
    SUM(o.total_amount)
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER
  ON CONFLICT (outlet_id, sale_date, hour_of_day) DO UPDATE SET
    total_orders = EXCLUDED.total_orders,
    total_revenue = EXCLUDED.total_revenue;

  INSERT INTO public.transaction_archive_orders (
    id, outlet_id, archive_date, storage_path, shift_id, table_id,
    table_number, table_area, order_number, order_type, status, customer_name,
    subtotal, discount_amount, tax_amount, service_charge, total_amount,
    cogs_amount, created_by, cashier_name, loyalty_member_id,
    created_at, updated_at, payments, refunds, promo_usages
  )
  SELECT
    o.id, o.outlet_id, p_business_date, p_storage_path, o.shift_id, o.table_id,
    t.table_number, t.area, o.order_number, o.order_type, o.status, o.customer_name,
    o.subtotal, o.discount_amount, o.tax_amount, o.service_charge, o.total_amount,
    o.cogs_amount, o.created_by, p.full_name, o.loyalty_member_id,
    o.created_at, o.updated_at,
    COALESCE((
      SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
      FROM public.payments pay WHERE pay.order_id = o.id
    ), '[]'::JSONB),
    COALESCE((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at, r.id)
      FROM public.refunds r WHERE r.order_id = o.id
    ), '[]'::JSONB),
    COALESCE((
      SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.created_at)
      FROM public.promo_usages pu WHERE pu.order_id = o.id
    ), '[]'::JSONB)
  FROM public.orders o
  LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
  LEFT JOIN public.profiles p ON p.id = o.created_by
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.transaction_archive_manifest (
    outlet_id, business_date, storage_path, checksum_sha256, order_count,
    total_amount, compressed_bytes, verified_at
  )
  VALUES (
    p_outlet_id, p_business_date, p_storage_path, p_checksum_sha256,
    p_order_count, p_total_amount, p_compressed_bytes, now()
  )
  ON CONFLICT (outlet_id, business_date) DO NOTHING;

  DELETE FROM public.stock_transactions st
  USING public.orders o
  WHERE st.order_id = o.id
    AND o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to;

  DELETE FROM public.orders o
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_transaction_archive(
  UUID, DATE, TEXT, TEXT, INTEGER, NUMERIC, BIGINT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_transaction_archive(
  UUID, DATE, TEXT, TEXT, INTEGER, NUMERIC, BIGINT
) TO service_role;

-- ── 5. View laporan aktif + arsip ──────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_payment_summary AS
SELECT outlet_id, pay_date, method,
  SUM(total_transactions)::BIGINT AS total_transactions,
  SUM(total_amount)::NUMERIC AS total_amount
FROM (
  SELECT p.outlet_id,
    (p.paid_at AT TIME ZONE 'Asia/Jakarta')::DATE AS pay_date,
    p.method, 1::BIGINT AS total_transactions, p.amount AS total_amount
  FROM public.payments p
  UNION ALL
  SELECT r.outlet_id,
    (r.created_at AT TIME ZONE 'Asia/Jakarta')::DATE,
    r.method, 0::BIGINT, -r.amount
  FROM public.refunds r
  UNION ALL
  SELECT a.outlet_id, a.pay_date, a.method,
    a.total_transactions, a.total_amount
  FROM public.archived_payment_sales_daily a
  UNION ALL
  SELECT a.outlet_id, a.refund_date, a.method,
    0::BIGINT, -a.total_amount
  FROM public.archived_refund_sales_daily a
) x
GROUP BY outlet_id, pay_date, method;

CREATE OR REPLACE VIEW public.v_payment_received_daily AS
SELECT outlet_id, pay_date,
  SUM(total_transactions)::BIGINT AS total_transactions,
  SUM(total_amount)::NUMERIC AS total_amount
FROM (
  SELECT p.outlet_id,
    (p.paid_at AT TIME ZONE 'Asia/Jakarta')::DATE AS pay_date,
    1::BIGINT AS total_transactions,
    p.amount AS total_amount
  FROM public.payments p
  UNION ALL
  SELECT a.outlet_id, a.pay_date, a.total_transactions, a.total_amount
  FROM public.archived_payment_sales_daily a
) x
GROUP BY outlet_id, pay_date;

CREATE OR REPLACE VIEW public.v_partial_refund_summary AS
SELECT outlet_id, refund_date,
  SUM(total_refunds)::BIGINT AS total_refunds,
  SUM(total_amount)::NUMERIC AS total_amount
FROM (
  SELECT r.outlet_id,
    (r.created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS refund_date,
    1::BIGINT AS total_refunds,
    r.amount AS total_amount
  FROM public.refunds r
  UNION ALL
  SELECT a.outlet_id, a.refund_date, a.total_refunds, a.total_amount
  FROM public.archived_refund_sales_daily a
) x
GROUP BY outlet_id, refund_date;

CREATE OR REPLACE VIEW public.v_order_hpp_unified AS
SELECT o.id AS order_id, o.outlet_id, o.created_at, o.status,
  COALESCE(o.cogs_amount, 0)::NUMERIC(14,2) AS hpp_total
FROM public.orders o
UNION ALL
SELECT a.id, a.outlet_id, a.created_at, a.status,
  COALESCE(a.cogs_amount, 0)::NUMERIC(14,2)
FROM public.transaction_archive_orders a;

CREATE OR REPLACE VIEW public.v_shift_summary AS
WITH live_paid AS (
  SELECT o.shift_id,
    COUNT(*)::INTEGER AS paid_orders
  FROM public.orders o
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), live_payment AS (
  SELECT o.shift_id,
    COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'cash'), 0)::NUMERIC AS cash_received,
    COALESCE(SUM(p.amount) FILTER (WHERE p.method <> 'cash'), 0)::NUMERIC AS non_cash_received
  FROM public.orders o
  JOIN public.payments p ON p.order_id = o.id
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), live_refund AS (
  SELECT o.shift_id,
    COALESCE(SUM(r.amount) FILTER (WHERE r.method = 'cash'), 0)::NUMERIC AS cash_refund,
    COALESCE(SUM(r.amount) FILTER (WHERE r.method <> 'cash'), 0)::NUMERIC AS non_cash_refund
  FROM public.orders o
  JOIN public.refunds r ON r.order_id = o.id
  WHERE o.status = 'paid' AND o.shift_id IS NOT NULL
  GROUP BY o.shift_id
), archive_paid AS (
  SELECT a.shift_id, COUNT(*)::INTEGER AS paid_orders
  FROM public.transaction_archive_orders a
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), archive_payment AS (
  SELECT a.shift_id,
    COALESCE(SUM((p.value->>'amount')::NUMERIC)
      FILTER (WHERE p.value->>'method' = 'cash'), 0) AS cash_received,
    COALESCE(SUM((p.value->>'amount')::NUMERIC)
      FILTER (WHERE p.value->>'method' <> 'cash'), 0) AS non_cash_received
  FROM public.transaction_archive_orders a
  CROSS JOIN LATERAL jsonb_array_elements(a.payments) p(value)
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), archive_refund AS (
  SELECT a.shift_id,
    COALESCE(SUM((r.value->>'amount')::NUMERIC)
      FILTER (WHERE r.value->>'method' = 'cash'), 0) AS cash_refund,
    COALESCE(SUM((r.value->>'amount')::NUMERIC)
      FILTER (WHERE r.value->>'method' <> 'cash'), 0) AS non_cash_refund
  FROM public.transaction_archive_orders a
  CROSS JOIN LATERAL jsonb_array_elements(a.refunds) r(value)
  WHERE a.shift_id IS NOT NULL
  GROUP BY a.shift_id
), combined AS (
  SELECT shift_id, paid_orders, 0::NUMERIC AS cash_received,
    0::NUMERIC AS non_cash_received, 0::NUMERIC AS cash_refund,
    0::NUMERIC AS non_cash_refund FROM live_paid
  UNION ALL
  SELECT shift_id, 0, cash_received, non_cash_received, 0, 0 FROM live_payment
  UNION ALL
  SELECT shift_id, 0, 0, 0, cash_refund, non_cash_refund FROM live_refund
  UNION ALL
  SELECT shift_id, paid_orders, 0, 0, 0, 0 FROM archive_paid
  UNION ALL
  SELECT shift_id, 0, cash_received, non_cash_received, 0, 0 FROM archive_payment
  UNION ALL
  SELECT shift_id, 0, 0, 0, cash_refund, non_cash_refund FROM archive_refund
), totals AS (
  SELECT shift_id,
    SUM(paid_orders)::INTEGER AS paid_orders,
    (SUM(cash_received) - SUM(cash_refund))::NUMERIC(14,2) AS cash_received,
    (SUM(non_cash_received) - SUM(non_cash_refund))::NUMERIC(14,2) AS non_cash_received
  FROM combined
  GROUP BY shift_id
)
SELECT s.id AS shift_id, s.outlet_id,
  COALESCE(t.cash_received, 0)::NUMERIC(14,2) AS cash_received,
  COALESCE(t.non_cash_received, 0)::NUMERIC(14,2) AS non_cash_received,
  COALESCE(t.paid_orders, 0)::INTEGER AS paid_orders
FROM public.shifts s
LEFT JOIN totals t ON t.shift_id = s.id;

CREATE OR REPLACE VIEW public.v_customer_summary AS
WITH history AS (
  SELECT o.loyalty_member_id AS member_id,
    o.total_amount - COALESCE(r.refund, 0) AS spent,
    o.created_at
  FROM public.orders o
  LEFT JOIN (
    SELECT order_id, SUM(amount) AS refund
    FROM public.refunds
    GROUP BY order_id
  ) r ON r.order_id = o.id
  WHERE o.status = 'paid' AND o.loyalty_member_id IS NOT NULL
  UNION ALL
  SELECT a.loyalty_member_id,
    a.total_amount - COALESCE((
      SELECT SUM((r.value->>'amount')::NUMERIC)
      FROM jsonb_array_elements(a.refunds) r(value)
    ), 0),
    a.created_at
  FROM public.transaction_archive_orders a
  WHERE a.loyalty_member_id IS NOT NULL
), totals AS (
  SELECT member_id, COUNT(*)::BIGINT AS total_orders,
    SUM(spent)::NUMERIC AS total_spent,
    MAX(created_at) AS last_order_at
  FROM history
  GROUP BY member_id
)
SELECT m.id AS member_id, m.outlet_id, m.name, m.phone, m.tier, m.points,
  COALESCE(t.total_orders, 0)::BIGINT AS total_orders,
  COALESCE(t.total_spent, 0)::NUMERIC AS total_spent,
  t.last_order_at
FROM public.loyalty_members m
LEFT JOIN totals t ON t.member_id = m.id;

CREATE OR REPLACE VIEW public.v_customer_order_history AS
SELECT o.id, o.outlet_id, o.loyalty_member_id, o.order_number,
  o.created_at, o.total_amount, o.status
FROM public.orders o
WHERE o.loyalty_member_id IS NOT NULL
UNION ALL
SELECT a.id, a.outlet_id, a.loyalty_member_id, a.order_number,
  a.created_at, a.total_amount, a.status
FROM public.transaction_archive_orders a
WHERE a.loyalty_member_id IS NOT NULL;

DO $$
DECLARE
  v TEXT;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'v_payment_summary',
    'v_payment_received_daily',
    'v_partial_refund_summary',
    'v_order_hpp_unified',
    'v_shift_summary',
    'v_customer_summary',
    'v_customer_order_history'
  ]
  LOOP
    EXECUTE format('ALTER VIEW public.%I SET (security_invoker = on)', v);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
  END LOOP;
END;
$$;

-- ── 6. Pagination lebih dulu, susun JSON detail hanya untuk halaman aktif ───
CREATE OR REPLACE FUNCTION public.list_orders_unified(
  p_outlet_id UUID,
  p_date_from TIMESTAMPTZ DEFAULT NULL,
  p_date_to TIMESTAMPTZ DEFAULT NULL,
  p_status public.order_status DEFAULT NULL,
  p_order_type public.order_type DEFAULT NULL,
  p_created_by UUID DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_offset INTEGER DEFAULT 0,
  p_limit INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      o.id, o.outlet_id, o.shift_id, o.table_id, o.order_number, o.order_type,
      o.status, o.customer_name, o.subtotal, o.discount_amount, o.tax_amount,
      o.service_charge, o.total_amount, o.stock_deducted, o.created_by,
      o.created_at, o.updated_at,
      CASE WHEN t.id IS NULL THEN NULL ELSE
        jsonb_build_object(
          'id', t.id, 'outlet_id', t.outlet_id, 'table_number', t.table_number,
          'area', t.area, 'capacity', t.capacity, 'status', t.status,
          'qr_token', t.qr_token, 'qr_code_url', t.qr_code_url,
          'qr_generated_at', t.qr_generated_at, 'is_active', t.is_active
        )
      END AS restaurant_tables,
      false AS archived,
      NULL::TEXT AS archive_path,
      NULL::TEXT AS archived_cashier_name,
      NULL::JSONB AS archived_payments
    FROM public.orders o
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id
    UNION ALL
    SELECT
      a.id, a.outlet_id, a.shift_id, a.table_id, a.order_number, a.order_type,
      a.status, a.customer_name, a.subtotal, a.discount_amount, a.tax_amount,
      a.service_charge, a.total_amount, true, a.created_by,
      a.created_at, a.updated_at,
      CASE WHEN a.table_number IS NULL THEN NULL ELSE
        jsonb_build_object(
          'id', a.table_id, 'outlet_id', a.outlet_id,
          'table_number', a.table_number, 'area', a.table_area,
          'capacity', 0, 'status', 'available', 'qr_token', NULL,
          'qr_code_url', NULL, 'qr_generated_at', NULL, 'is_active', false
        )
      END,
      true, a.storage_path, a.cashier_name, a.payments
    FROM public.transaction_archive_orders a
  ), filtered AS (
    SELECT *
    FROM base b
    WHERE b.outlet_id = p_outlet_id
      AND (p_date_from IS NULL OR b.created_at >= p_date_from)
      AND (p_date_to IS NULL OR b.created_at <= p_date_to)
      AND (p_status IS NULL OR b.status = p_status)
      AND (p_order_type IS NULL OR b.order_type = p_order_type)
      AND (p_created_by IS NULL OR b.created_by = p_created_by)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR b.order_number ILIKE '%' || btrim(p_search) || '%'
        OR COALESCE(b.customer_name, '') ILIKE '%' || btrim(p_search) || '%'
      )
  ), page AS (
    SELECT *
    FROM filtered
    ORDER BY created_at DESC, id DESC
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 1000))
  ), enriched AS (
    SELECT
      to_jsonb(p) - 'archived_payments'
      || jsonb_build_object(
        'order_items',
        CASE WHEN p.archived THEN '[]'::JSONB ELSE COALESCE((
          SELECT jsonb_agg(
            to_jsonb(oi) || jsonb_build_object(
              'menu_items', jsonb_build_object(
                'id', mi.id,
                'name', COALESCE(mi.name, 'Menu dihapus')
              )
            )
            ORDER BY oi.id
          )
          FROM public.order_items oi
          LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
          WHERE oi.order_id = p.id
        ), '[]'::JSONB) END,
        'payments',
        CASE WHEN p.archived THEN COALESCE(p.archived_payments, '[]'::JSONB)
        ELSE COALESCE((
          SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
          FROM public.payments pay
          WHERE pay.order_id = p.id
        ), '[]'::JSONB) END
      ) AS row_data,
      p.created_at,
      p.id
    FROM page p
  )
  SELECT jsonb_build_object(
    'total_count', (SELECT COUNT(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(e.row_data ORDER BY e.created_at DESC, e.id DESC)
      FROM enriched e
    ), '[]'::JSONB)
  );
$$;

REVOKE ALL ON FUNCTION public.list_orders_unified(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type,
  UUID, TEXT, INTEGER, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_orders_unified(
  UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type,
  UUID, TEXT, INTEGER, INTEGER
) TO authenticated;

-- Simpan log operasi 90 hari; data transaksi utama tetap mengikuti retensi.
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'cleanup-transaction-archive-runs';

SELECT cron.schedule(
  'cleanup-transaction-archive-runs',
  '50 19 * * *',
  $$DELETE FROM public.transaction_archive_runs
    WHERE started_at < now() - INTERVAL '90 days';$$
);


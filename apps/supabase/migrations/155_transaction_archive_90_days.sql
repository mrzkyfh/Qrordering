-- 155_transaction_archive_90_days.sql
-- Arsip transaksi lunas lebih dari 90 hari ke Storage privat.
--
-- Prinsip keselamatan:
--   * hanya order berstatus paid yang boleh diarsipkan;
--   * file harus dibuat + dibaca ulang oleh Edge Function sebelum finalize;
--   * ringkasan laporan dan indeks pencarian disimpan sebelum raw order dihapus;
--   * seluruh finalize berlangsung dalam satu transaksi database.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'transaction-archives',
  'transaction-archives',
  false,
  52428800,
  ARRAY['application/gzip']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE TABLE IF NOT EXISTS public.transaction_archive_manifest (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  business_date DATE NOT NULL,
  storage_path TEXT NOT NULL,
  checksum_sha256 TEXT NOT NULL,
  order_count INTEGER NOT NULL CHECK (order_count > 0),
  total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  compressed_bytes BIGINT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed')),
  verified_at TIMESTAMPTZ NOT NULL,
  archived_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (outlet_id, business_date),
  UNIQUE (storage_path)
);

CREATE TABLE IF NOT EXISTS public.transaction_archive_orders (
  id UUID PRIMARY KEY,
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  archive_date DATE NOT NULL,
  storage_path TEXT NOT NULL,
  shift_id UUID,
  table_id UUID,
  table_number TEXT,
  table_area TEXT,
  order_number TEXT NOT NULL,
  order_type public.order_type NOT NULL,
  status public.order_status NOT NULL DEFAULT 'paid',
  customer_name TEXT,
  subtotal NUMERIC(14,2) NOT NULL DEFAULT 0,
  discount_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  tax_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  service_charge NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  cogs_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  created_by UUID,
  cashier_name TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  payments JSONB NOT NULL DEFAULT '[]'::jsonb,
  archived_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status = 'paid')
);

CREATE INDEX IF NOT EXISTS idx_archive_orders_outlet_created
  ON public.transaction_archive_orders(outlet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_archive_orders_outlet_number
  ON public.transaction_archive_orders(outlet_id, order_number);
CREATE INDEX IF NOT EXISTS idx_archive_orders_creator_created
  ON public.transaction_archive_orders(created_by, created_at DESC);

CREATE TABLE IF NOT EXISTS public.archived_item_sales_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  sales_date DATE NOT NULL,
  menu_item_id UUID,
  menu_name TEXT NOT NULL,
  price NUMERIC(14,2) NOT NULL DEFAULT 0,
  category_id UUID,
  category_name TEXT,
  department_id UUID,
  department_name TEXT,
  department_color TEXT,
  qty_sold BIGINT NOT NULL DEFAULT 0,
  total_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  order_count BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, sales_date, menu_name)
);

CREATE TABLE IF NOT EXISTS public.archived_extra_sales_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  sales_date DATE NOT NULL,
  extra_id UUID,
  extra_name TEXT,
  option_id UUID,
  option_name TEXT NOT NULL,
  option_price NUMERIC(14,2) NOT NULL DEFAULT 0,
  qty_selected BIGINT NOT NULL DEFAULT 0,
  total_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, sales_date, option_name)
);

CREATE TABLE IF NOT EXISTS public.archived_payment_sales_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  pay_date DATE NOT NULL,
  method public.payment_method NOT NULL,
  total_transactions BIGINT NOT NULL DEFAULT 0,
  total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, pay_date, method)
);

CREATE TABLE IF NOT EXISTS public.archived_cashier_sales_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  work_date DATE NOT NULL,
  kasir_id UUID,
  kasir_name TEXT NOT NULL,
  total_orders BIGINT NOT NULL DEFAULT 0,
  total_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_discount_given NUMERIC(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, work_date, kasir_name)
);

CREATE TABLE IF NOT EXISTS public.archived_peak_hours_daily (
  outlet_id UUID NOT NULL REFERENCES public.outlets(id) ON DELETE CASCADE,
  sale_date DATE NOT NULL,
  hour_of_day INTEGER NOT NULL CHECK (hour_of_day BETWEEN 0 AND 23),
  total_orders INTEGER NOT NULL DEFAULT 0,
  total_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id, sale_date, hour_of_day)
);

ALTER TABLE public.sales_daily_summary
  ADD COLUMN IF NOT EXISTS cogs NUMERIC(14,2) NOT NULL DEFAULT 0;

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'transaction_archive_manifest',
    'transaction_archive_orders',
    'archived_item_sales_daily',
    'archived_extra_sales_daily',
    'archived_payment_sales_daily',
    'archived_cashier_sales_daily',
    'archived_peak_hours_daily'
  ]
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_select', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_owner() OR outlet_id = public.auth_outlet_id())',
      t || '_select', t
    );
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
  END LOOP;
END;
$$;

-- Hari yang siap diarsipkan. Satu eksekusi dibatasi agar Edge Function tidak
-- melewati batas waktu; sisanya diteruskan oleh jadwal berikutnya.
CREATE OR REPLACE FUNCTION public.transaction_archive_candidates(
  p_keep_days INTEGER DEFAULT 90,
  p_limit INTEGER DEFAULT 5
)
RETURNS TABLE (outlet_id UUID, business_date DATE, order_count BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    o.outlet_id,
    (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS business_date,
    COUNT(*)::BIGINT
  FROM public.orders o
  WHERE o.status = 'paid'
    AND (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
      < public.jkt_today() - GREATEST(p_keep_days, 90)
    AND NOT EXISTS (
      SELECT 1
      FROM public.transaction_archive_manifest m
      WHERE m.outlet_id = o.outlet_id
        AND m.business_date = (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
    )
  GROUP BY o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
  ORDER BY business_date, o.outlet_id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 5), 10));
$$;

-- Payload lengkap per hari. Hanya service_role yang dapat memanggil fungsi ini.
CREATE OR REPLACE FUNCTION public.build_transaction_archive_payload(
  p_outlet_id UUID,
  p_business_date DATE
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH bounds AS (
    SELECT
      p_business_date::TIMESTAMP AT TIME ZONE 'Asia/Jakarta' AS from_ts,
      (p_business_date + 1)::TIMESTAMP AT TIME ZONE 'Asia/Jakarta' AS to_ts
  ), archived_orders AS (
    SELECT o.*
    FROM public.orders o, bounds b
    WHERE o.outlet_id = p_outlet_id
      AND o.status = 'paid'
      AND o.created_at >= b.from_ts
      AND o.created_at < b.to_ts
    ORDER BY o.created_at, o.id
  )
  SELECT jsonb_build_object(
    'schema_version', 1,
    'outlet_id', p_outlet_id,
    'business_date', p_business_date,
    'generated_at', now(),
    'order_count', COUNT(*),
    'orders', COALESCE(jsonb_agg(
      to_jsonb(o)
      || jsonb_build_object(
        'restaurant_tables', (
          SELECT to_jsonb(t)
          FROM public.restaurant_tables t
          WHERE t.id = o.table_id
        ),
        'cashier', (
          SELECT jsonb_build_object('id', p.id, 'full_name', p.full_name)
          FROM public.profiles p
          WHERE p.id = o.created_by
        ),
        'order_items', COALESCE((
          SELECT jsonb_agg(
            to_jsonb(oi)
            || jsonb_build_object(
              'menu_items', jsonb_build_object(
                'id', mi.id,
                'name', COALESCE(mi.name, 'Menu dihapus'),
                'category_id', mi.category_id
              ),
              'order_item_options', COALESCE((
                SELECT jsonb_agg(to_jsonb(oio) ORDER BY oio.created_at, oio.id)
                FROM public.order_item_options oio
                WHERE oio.order_item_id = oi.id
              ), '[]'::jsonb)
            )
            ORDER BY oi.id
          )
          FROM public.order_items oi
          LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
          WHERE oi.order_id = o.id
        ), '[]'::jsonb),
        'payments', COALESCE((
          SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
          FROM public.payments pay
          WHERE pay.order_id = o.id
        ), '[]'::jsonb),
        'refunds', COALESCE((
          SELECT jsonb_agg(
            to_jsonb(r)
            || jsonb_build_object(
              'refund_items', COALESCE((
                SELECT jsonb_agg(to_jsonb(ri) ORDER BY ri.id)
                FROM public.refund_items ri
                WHERE ri.refund_id = r.id
              ), '[]'::jsonb)
            )
            ORDER BY r.created_at, r.id
          )
          FROM public.refunds r
          WHERE r.order_id = o.id
        ), '[]'::jsonb),
        'order_audit_log', COALESCE((
          SELECT jsonb_agg(to_jsonb(al) ORDER BY al.created_at, al.id)
          FROM public.order_audit_log al
          WHERE al.order_id = o.id
        ), '[]'::jsonb),
        'promo_usages', COALESCE((
          SELECT jsonb_agg(to_jsonb(pu) ORDER BY pu.created_at)
          FROM public.promo_usages pu
          WHERE pu.order_id = o.id
        ), '[]'::jsonb),
        'stock_transactions', COALESCE((
          SELECT jsonb_agg(to_jsonb(st) ORDER BY st.created_at, st.id)
          FROM public.stock_transactions st
          WHERE st.order_id = o.id
        ), '[]'::jsonb)
      )
      ORDER BY o.created_at, o.id
    ), '[]'::jsonb)
  )
  FROM archived_orders o;
$$;

-- Finalize dipanggil hanya setelah Edge Function berhasil mengunggah, mengunduh
-- ulang, membuka gzip, mencocokkan checksum, tanggal, outlet, dan jumlah order.
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

  -- Ringkasan utama.
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
    ), '{}'::jsonb),
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
    ), '{}'::jsonb),
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
    ), '{}'::jsonb),
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

  -- Ringkasan per menu/kategori/departemen.
  INSERT INTO public.archived_item_sales_daily AS a (
    outlet_id, sales_date, menu_item_id, menu_name, price,
    category_id, category_name, department_id, department_name, department_color,
    qty_sold, total_revenue, order_count
  )
  SELECT
    p_outlet_id, p_business_date, oi.menu_item_id,
    COALESCE(mi.name, 'Menu dihapus'), MAX(oi.unit_price),
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
  GROUP BY oi.menu_item_id, COALESCE(mi.name, 'Menu dihapus'), mc.id, mc.name, md.id, md.name, md.color
  ON CONFLICT (outlet_id, sales_date, menu_name) DO UPDATE SET
    menu_item_id = EXCLUDED.menu_item_id,
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
    outlet_id, sales_date, extra_id, extra_name, option_id, option_name,
    option_price, qty_selected, total_revenue
  )
  SELECT
    p_outlet_id, p_business_date,
    MIN(oio.menu_extra_id), MIN(oio.extra_name), oio.menu_extra_option_id,
    COALESCE(oio.option_name, 'Tambahan dihapus'), MAX(oio.price),
    COUNT(oio.id)::BIGINT,
    COALESCE(SUM(oio.price * (oi.quantity - COALESCE(oi.refunded_qty, 0))), 0)
  FROM public.order_item_options oio
  JOIN public.order_items oi ON oi.id = oio.order_item_id
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY oio.menu_extra_option_id, COALESCE(oio.option_name, 'Tambahan dihapus')
  ON CONFLICT (outlet_id, sales_date, option_name) DO UPDATE SET
    extra_id = EXCLUDED.extra_id,
    extra_name = EXCLUDED.extra_name,
    option_id = EXCLUDED.option_id,
    option_price = EXCLUDED.option_price,
    qty_selected = EXCLUDED.qty_selected,
    total_revenue = EXCLUDED.total_revenue;

  INSERT INTO public.archived_payment_sales_daily AS a (
    outlet_id, pay_date, method, total_transactions, total_amount
  )
  SELECT p_outlet_id, p_business_date, x.method,
    SUM(x.txn)::BIGINT, SUM(x.amount)::NUMERIC
  FROM (
    SELECT pay.method, 1::BIGINT AS txn, pay.amount
    FROM public.payments pay
    JOIN public.orders o ON o.id = pay.order_id
    WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
      AND o.created_at >= v_from AND o.created_at < v_to
    UNION ALL
    SELECT r.method, 0::BIGINT, -r.amount
    FROM public.refunds r
    JOIN public.orders o ON o.id = r.order_id
    WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
      AND o.created_at >= v_from AND o.created_at < v_to
  ) x
  GROUP BY x.method
  ON CONFLICT (outlet_id, pay_date, method) DO UPDATE SET
    total_transactions = EXCLUDED.total_transactions,
    total_amount = EXCLUDED.total_amount;

  INSERT INTO public.archived_cashier_sales_daily AS a (
    outlet_id, work_date, kasir_id, kasir_name, total_orders,
    total_revenue, total_discount_given
  )
  SELECT
    p_outlet_id, p_business_date, o.created_by,
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
  ON CONFLICT (outlet_id, work_date, kasir_name) DO UPDATE SET
    kasir_id = EXCLUDED.kasir_id,
    total_orders = EXCLUDED.total_orders,
    total_revenue = EXCLUDED.total_revenue,
    total_discount_given = EXCLUDED.total_discount_given;

  INSERT INTO public.archived_peak_hours_daily AS a (
    outlet_id, sale_date, hour_of_day, total_orders, total_revenue
  )
  SELECT
    p_outlet_id, p_business_date,
    EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER,
    COUNT(*)::INTEGER, SUM(o.total_amount)
  FROM public.orders o
  WHERE o.outlet_id = p_outlet_id AND o.status = 'paid'
    AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER
  ON CONFLICT (outlet_id, sale_date, hour_of_day) DO UPDATE SET
    total_orders = EXCLUDED.total_orders,
    total_revenue = EXCLUDED.total_revenue;

  -- Indeks ringan untuk daftar transaksi historis.
  INSERT INTO public.transaction_archive_orders (
    id, outlet_id, archive_date, storage_path, shift_id, table_id,
    table_number, table_area, order_number, order_type, status, customer_name,
    subtotal, discount_amount, tax_amount, service_charge, total_amount,
    cogs_amount, created_by, cashier_name, created_at, updated_at, payments
  )
  SELECT
    o.id, o.outlet_id, p_business_date, p_storage_path, o.shift_id, o.table_id,
    t.table_number, t.area, o.order_number, o.order_type, o.status, o.customer_name,
    o.subtotal, o.discount_amount, o.tax_amount, o.service_charge, o.total_amount,
    o.cogs_amount, o.created_by, p.full_name, o.created_at, o.updated_at,
    COALESCE((
      SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
      FROM public.payments pay WHERE pay.order_id = o.id
    ), '[]'::jsonb)
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

  -- Ledger stok order telah ikut masuk file privat. Hapus sebelum FK order
  -- menjadi NULL agar baris dapat ditemukan secara pasti.
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

-- Daftar terpadu: transaksi aktif + indeks arsip. Detail arsip diambil dari
-- Storage melalui Edge Function yang memeriksa hak akses pengguna.
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
  WITH combined AS (
    SELECT
      o.id, o.outlet_id, o.shift_id, o.table_id, o.order_number, o.order_type,
      o.status, o.customer_name, o.subtotal, o.discount_amount, o.tax_amount,
      o.service_charge, o.total_amount, o.stock_deducted, o.created_by,
      o.created_at, o.updated_at,
      CASE WHEN t.id IS NULL THEN NULL ELSE
        jsonb_build_object('id', t.id, 'outlet_id', t.outlet_id,
          'table_number', t.table_number, 'area', t.area, 'capacity', t.capacity,
          'status', t.status, 'qr_token', t.qr_token, 'qr_code_url', t.qr_code_url,
          'qr_generated_at', t.qr_generated_at, 'is_active', t.is_active)
      END AS restaurant_tables,
      COALESCE((
        SELECT jsonb_agg(
          to_jsonb(oi) || jsonb_build_object(
            'menu_items', jsonb_build_object('id', mi.id, 'name', COALESCE(mi.name, 'Menu dihapus'))
          )
          ORDER BY oi.id
        )
        FROM public.order_items oi
        LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
        WHERE oi.order_id = o.id
      ), '[]'::jsonb) AS order_items,
      COALESCE((
        SELECT jsonb_agg(to_jsonb(pay) ORDER BY pay.paid_at, pay.id)
        FROM public.payments pay WHERE pay.order_id = o.id
      ), '[]'::jsonb) AS payments,
      false AS archived,
      NULL::TEXT AS archive_path,
      NULL::TEXT AS archived_cashier_name
    FROM public.orders o
    LEFT JOIN public.restaurant_tables t ON t.id = o.table_id

    UNION ALL

    SELECT
      a.id, a.outlet_id, a.shift_id, a.table_id, a.order_number, a.order_type,
      a.status, a.customer_name, a.subtotal, a.discount_amount, a.tax_amount,
      a.service_charge, a.total_amount, true, a.created_by,
      a.created_at, a.updated_at,
      CASE WHEN a.table_number IS NULL THEN NULL ELSE
        jsonb_build_object('id', a.table_id, 'outlet_id', a.outlet_id,
          'table_number', a.table_number, 'area', a.table_area, 'capacity', 0,
          'status', 'available', 'qr_token', NULL, 'qr_code_url', NULL,
          'qr_generated_at', NULL, 'is_active', false)
      END,
      '[]'::jsonb,
      a.payments,
      true,
      a.storage_path,
      a.cashier_name
    FROM public.transaction_archive_orders a
  ), filtered AS (
    SELECT *
    FROM combined c
    WHERE c.outlet_id = p_outlet_id
      AND (p_date_from IS NULL OR c.created_at >= p_date_from)
      AND (p_date_to IS NULL OR c.created_at <= p_date_to)
      AND (p_status IS NULL OR c.status = p_status)
      AND (p_order_type IS NULL OR c.order_type = p_order_type)
      AND (p_created_by IS NULL OR c.created_by = p_created_by)
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR c.order_number ILIKE '%' || btrim(p_search) || '%'
        OR COALESCE(c.customer_name, '') ILIKE '%' || btrim(p_search) || '%'
      )
  ), page AS (
    SELECT *
    FROM filtered
    ORDER BY created_at DESC, id DESC
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 1000))
  )
  SELECT jsonb_build_object(
    'total_count', (SELECT COUNT(*) FROM filtered),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC, p.id DESC)
      FROM page p
    ), '[]'::jsonb)
  );
$$;

REVOKE ALL ON FUNCTION public.transaction_archive_candidates(INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.build_transaction_archive_payload(UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_transaction_archive(UUID, DATE, TEXT, TEXT, INTEGER, NUMERIC, BIGINT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.transaction_archive_candidates(INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.build_transaction_archive_payload(UUID, DATE) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_transaction_archive(UUID, DATE, TEXT, TEXT, INTEGER, NUMERIC, BIGINT) TO service_role;

REVOKE ALL ON FUNCTION public.list_orders_unified(UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type, UUID, TEXT, INTEGER, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_orders_unified(UUID, TIMESTAMPTZ, TIMESTAMPTZ, public.order_status, public.order_type, UUID, TEXT, INTEGER, INTEGER)
  TO authenticated;

-- Laporan terpadu. Setelah finalize, raw untuk hari tersebut sudah tidak ada;
-- ringkasan arsip mengisi baris historis dengan bentuk kolom yang sama.
CREATE OR REPLACE VIEW public.v_daily_sales AS
SELECT
  o.outlet_id,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  COUNT(*)::INTEGER AS total_orders,
  COALESCE(SUM(o.subtotal), 0) AS gross_revenue,
  COALESCE(SUM(o.discount_amount), 0) AS total_discount,
  COALESCE(SUM(o.tax_amount), 0) AS total_tax,
  COALESCE(SUM(o.service_charge), 0) AS total_service_charge,
  COALESCE(SUM(o.total_amount - COALESCE(rf.refund, 0)), 0) AS net_revenue
FROM public.orders o
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM public.refunds GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid'
GROUP BY o.outlet_id, ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT
  s.outlet_id, s.sales_date::TEXT, s.order_count, s.gross, s.discount,
  s.tax, s.service, s.net
FROM public.sales_daily_summary s
JOIN public.transaction_archive_manifest m
  ON m.outlet_id = s.outlet_id AND m.business_date = s.sales_date;

CREATE OR REPLACE VIEW public.v_payment_summary AS
SELECT outlet_id, pay_date, method, SUM(txn) AS total_transactions, SUM(amt) AS total_amount
FROM (
  SELECT p.outlet_id, (p.paid_at AT TIME ZONE 'Asia/Jakarta')::DATE AS pay_date,
    p.method, 1::INTEGER AS txn, p.amount AS amt
  FROM public.payments p
  UNION ALL
  SELECT r.outlet_id, (r.created_at AT TIME ZONE 'Asia/Jakarta')::DATE,
    r.method, 0::INTEGER, -r.amount
  FROM public.refunds r
  UNION ALL
  SELECT a.outlet_id, a.pay_date, a.method, a.total_transactions::INTEGER, a.total_amount
  FROM public.archived_payment_sales_daily a
) x
GROUP BY outlet_id, pay_date, method;

CREATE OR REPLACE VIEW public.v_top_menu_items AS
SELECT oi.menu_item_id, mi.outlet_id, mi.name AS menu_item_name, mc.name AS category_name,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::INTEGER AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price) AS total_revenue
FROM public.order_items oi
JOIN public.menu_items mi ON mi.id = oi.menu_item_id
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY oi.menu_item_id, mi.outlet_id, mi.name, mc.name,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT a.menu_item_id, a.outlet_id, a.menu_name, a.category_name,
  a.sales_date::TEXT, a.qty_sold::INTEGER, a.total_revenue
FROM public.archived_item_sales_daily a;

CREATE OR REPLACE VIEW public.v_category_sales AS
SELECT mi.outlet_id, mc.id AS category_id, mc.name AS category_name,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::INTEGER AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price) AS total_revenue,
  COUNT(DISTINCT o.id)::INTEGER AS total_orders
FROM public.order_items oi
JOIN public.menu_items mi ON mi.id = oi.menu_item_id
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
WHERE o.status = 'paid'
GROUP BY mi.outlet_id, mc.id, mc.name, ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT a.outlet_id, a.category_id, a.category_name, a.sales_date::TEXT,
  SUM(a.qty_sold)::INTEGER, SUM(a.total_revenue), SUM(a.order_count)::INTEGER
FROM public.archived_item_sales_daily a
GROUP BY a.outlet_id, a.category_id, a.category_name, a.sales_date;

CREATE OR REPLACE VIEW public.v_department_sales AS
SELECT COALESCE(md.outlet_id, mi.outlet_id) AS outlet_id, md.id AS department_id,
  COALESCE(md.name, 'Tanpa Departemen') AS department_name, md.color,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  COUNT(DISTINCT o.id)::INTEGER AS total_orders,
  SUM(oi.quantity - oi.refunded_qty)::INTEGER AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price) AS total_revenue
FROM public.order_items oi
JOIN public.menu_items mi ON mi.id = oi.menu_item_id
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
LEFT JOIN public.menu_departments md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY COALESCE(md.outlet_id, mi.outlet_id), md.id, COALESCE(md.name, 'Tanpa Departemen'),
  md.color, ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT a.outlet_id, a.department_id, COALESCE(a.department_name, 'Tanpa Departemen'),
  a.department_color, a.sales_date::TEXT, SUM(a.order_count)::INTEGER,
  SUM(a.qty_sold)::INTEGER, SUM(a.total_revenue)
FROM public.archived_item_sales_daily a
GROUP BY a.outlet_id, a.department_id, COALESCE(a.department_name, 'Tanpa Departemen'),
  a.department_color, a.sales_date;

CREATE OR REPLACE VIEW public.v_menu_sales AS
SELECT mi.outlet_id, mi.id AS menu_item_id, mi.name AS menu_name, mi.price,
  mc.name AS category_name, md.name AS department_name,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  SUM(oi.quantity - oi.refunded_qty)::INTEGER AS qty_sold,
  SUM(oi.subtotal - oi.refunded_qty * oi.unit_price) AS total_revenue,
  COUNT(DISTINCT o.id)::INTEGER AS order_count
FROM public.order_items oi
JOIN public.menu_items mi ON mi.id = oi.menu_item_id
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
LEFT JOIN public.menu_departments md ON md.id = mc.department_id
WHERE o.status = 'paid'
GROUP BY mi.outlet_id, mi.id, mi.name, mi.price, mc.name, md.name,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT a.outlet_id, a.menu_item_id, a.menu_name, a.price::NUMERIC(12,2), a.category_name,
  a.department_name, a.sales_date::TEXT, a.qty_sold::INTEGER,
  a.total_revenue, a.order_count::INTEGER
FROM public.archived_item_sales_daily a;

CREATE OR REPLACE VIEW public.v_extra_option_sales AS
SELECT o.outlet_id, me.id AS extra_id, COALESCE(oio.extra_name, me.name) AS extra_name,
  meo.id AS option_id, COALESCE(oio.option_name, meo.name) AS option_name,
  meo.price AS option_price,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT AS sale_date,
  COUNT(oio.id)::INTEGER AS qty_selected,
  COALESCE(SUM(oio.price * (oi.quantity - COALESCE(oi.refunded_qty, 0))), 0) AS total_revenue
FROM public.menu_extras me
JOIN public.menu_extra_options meo ON meo.extra_id = me.id
LEFT JOIN public.order_item_options oio ON oio.menu_extra_option_id = meo.id
LEFT JOIN public.order_items oi ON oi.id = oio.order_item_id
LEFT JOIN public.orders o ON o.id = oi.order_id AND o.status = 'paid'
GROUP BY o.outlet_id, me.id, COALESCE(oio.extra_name, me.name), meo.id,
  COALESCE(oio.option_name, meo.name), meo.price,
  ((o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE)::TEXT
UNION ALL
SELECT a.outlet_id, a.extra_id, a.extra_name, a.option_id, a.option_name,
  a.option_price::NUMERIC(12,2), a.sales_date::TEXT, a.qty_selected::INTEGER, a.total_revenue
FROM public.archived_extra_sales_daily a;

CREATE OR REPLACE VIEW public.v_kasir_performance AS
SELECT o.outlet_id, o.created_by AS kasir_id, p.full_name AS kasir_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS work_date,
  COUNT(*) AS total_orders,
  SUM(o.total_amount - COALESCE(rf.refund, 0)) AS total_revenue,
  AVG(o.total_amount - COALESCE(rf.refund, 0)) AS avg_order_value,
  SUM(o.discount_amount) AS total_discount_given
FROM public.orders o
JOIN public.profiles p ON p.id = o.created_by
LEFT JOIN (
  SELECT order_id, SUM(amount) AS refund FROM public.refunds GROUP BY order_id
) rf ON rf.order_id = o.id
WHERE o.status = 'paid' AND o.created_by IS NOT NULL
GROUP BY o.outlet_id, o.created_by, p.full_name,
  (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE
UNION ALL
SELECT a.outlet_id, a.kasir_id, a.kasir_name, a.work_date,
  a.total_orders, a.total_revenue,
  CASE WHEN a.total_orders = 0 THEN 0 ELSE a.total_revenue / a.total_orders END,
  a.total_discount_given
FROM public.archived_cashier_sales_daily a;

CREATE OR REPLACE VIEW public.v_peak_hours AS
SELECT o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE AS sale_date,
  EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER AS hour_of_day,
  COUNT(*)::INTEGER AS total_orders, SUM(o.total_amount) AS total_revenue
FROM public.orders o
WHERE o.status = 'paid'
GROUP BY o.outlet_id, (o.created_at AT TIME ZONE 'Asia/Jakarta')::DATE,
  EXTRACT(HOUR FROM o.created_at AT TIME ZONE 'Asia/Jakarta')::INTEGER
UNION ALL
SELECT outlet_id, sale_date, hour_of_day, total_orders, total_revenue
FROM public.archived_peak_hours_daily;

-- v_tax_report memakai bentuk yang sama dengan v_daily_sales.
CREATE OR REPLACE VIEW public.v_tax_report AS
SELECT outlet_id, sale_date, total_orders, gross_revenue, total_discount,
  total_tax, total_service_charge, net_revenue,
  GREATEST(
    gross_revenue - total_discount + total_tax + total_service_charge - net_revenue,
    0
  ) AS total_refund
FROM public.v_daily_sales;

-- Laba rugi memakai ringkasan terverifikasi untuk bulan yang sudah diarsipkan.
CREATE OR REPLACE VIEW public.v_profit_loss AS
WITH monthly_revenue AS (
  SELECT
    v.outlet_id,
    LEFT(v.sale_date, 7) AS month,
    SUM(v.gross_revenue) AS gross_revenue,
    SUM(v.total_discount) AS total_discount,
    SUM(v.gross_revenue - v.total_discount + v.total_tax + v.total_service_charge - v.net_revenue) AS total_refund,
    SUM(v.net_revenue) AS net_revenue
  FROM public.v_daily_sales v
  GROUP BY v.outlet_id, LEFT(v.sale_date, 7)
), monthly_live_hpp AS (
  SELECT h.outlet_id,
    to_char(h.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM') AS month,
    SUM(h.hpp_total) AS cost_of_goods
  FROM public.v_order_hpp h
  WHERE h.status = 'paid'
  GROUP BY h.outlet_id, to_char(h.created_at AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
), monthly_archive_hpp AS (
  SELECT s.outlet_id, to_char(s.sales_date, 'YYYY-MM') AS month, SUM(s.cogs) AS cost_of_goods
  FROM public.sales_daily_summary s
  JOIN public.transaction_archive_manifest m
    ON m.outlet_id = s.outlet_id AND m.business_date = s.sales_date
  GROUP BY s.outlet_id, to_char(s.sales_date, 'YYYY-MM')
), monthly_hpp AS (
  SELECT outlet_id, month, SUM(cost_of_goods) AS cost_of_goods
  FROM (
    SELECT * FROM monthly_live_hpp
    UNION ALL
    SELECT * FROM monthly_archive_hpp
  ) h
  GROUP BY outlet_id, month
), monthly_expenses AS (
  SELECT e.outlet_id, to_char(e.expense_date::TIMESTAMPTZ, 'YYYY-MM') AS month,
    COALESCE(SUM(e.amount) FILTER (WHERE e.category <> 'bahan_baku'), 0) AS total_expenses
  FROM public.expenses e
  GROUP BY e.outlet_id, to_char(e.expense_date::TIMESTAMPTZ, 'YYYY-MM')
), all_periods AS (
  SELECT outlet_id, month FROM monthly_revenue
  UNION SELECT outlet_id, month FROM monthly_hpp
  UNION SELECT outlet_id, month FROM monthly_expenses
)
SELECT p.outlet_id, p.month,
  COALESCE(r.gross_revenue, 0) AS gross_revenue,
  COALESCE(r.total_discount, 0) AS total_discount,
  COALESCE(r.total_refund, 0) AS total_refund,
  COALESCE(r.net_revenue, 0) AS net_revenue,
  COALESCE(h.cost_of_goods, 0) AS cost_of_goods,
  COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0) AS gross_profit,
  COALESCE(e.total_expenses, 0) AS total_expenses,
  COALESCE(r.net_revenue, 0) - COALESCE(h.cost_of_goods, 0) - COALESCE(e.total_expenses, 0) AS net_profit
FROM all_periods p
LEFT JOIN monthly_revenue r ON r.outlet_id = p.outlet_id AND r.month = p.month
LEFT JOIN monthly_hpp h ON h.outlet_id = p.outlet_id AND h.month = p.month
LEFT JOIN monthly_expenses e ON e.outlet_id = p.outlet_id AND e.month = p.month;

DO $$
DECLARE
  v TEXT;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'v_daily_sales', 'v_payment_summary', 'v_top_menu_items',
    'v_category_sales', 'v_department_sales', 'v_menu_sales',
    'v_extra_option_sales', 'v_kasir_performance', 'v_peak_hours',
    'v_tax_report', 'v_profit_loss'
  ]
  LOOP
    EXECUTE format('ALTER VIEW public.%I SET (security_invoker = on)', v);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
  END LOOP;
END;
$$;

-- 02:35 WIB: minta Edge Function mengarsipkan maksimal lima hari tertua.
-- Secret dibaca saat job berjalan; nilainya disimpan di Supabase Vault,
-- tidak pernah ditulis ke repository atau cron.command.
SELECT cron.schedule(
  'archive-paid-orders-90-days',
  '35 19 * * *',
  $cron$
  SELECT net.http_post(
    url := 'https://jstdtalbihxlbpfsisab.supabase.co/functions/v1/archive-orders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-archive-secret', (
        SELECT decrypted_secret
        FROM vault.decrypted_secrets
        WHERE name = 'transaction_archive_job_secret'
        LIMIT 1
      )
    ),
    body := '{"keep_days":90,"limit_days":5}'::jsonb,
    timeout_milliseconds := 50000
  );
  $cron$
);

COMMENT ON TABLE public.transaction_archive_manifest IS
  'Manifest file gzip privat yang telah dibaca ulang dan diverifikasi sebelum raw transaksi dihapus.';
COMMENT ON TABLE public.transaction_archive_orders IS
  'Indeks ringan agar transaksi lama tetap dapat dicari; detail lengkap berada di Storage privat.';

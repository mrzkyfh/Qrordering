-- 121_staff_daily_basis.sql
-- Awetkan BASIS komisi per staf per hari — sekarang ia lenyap total setelah 6 bulan.
--
-- MASALAH. Komisi dihitung sepenuhnya di browser (CommissionManager.tsx):
--     commission = basis='percent' ? revenue * rule.value / 100 : orders * rule.value
-- dari v_kasir_performance, dan TIDAK PERNAH disimpan. Dua akibatnya:
--
--   (1) Angkanya berubah RETROAKTIF. Refund yang masuk bulan depan mengubah
--       v_kasir_performance, sehingga komisi bulan lalu — yang sudah dibayarkan —
--       menampilkan angka berbeda hari ini.
--   (2) Setelah prune_old_orders (110) menghapus order > 6 bulan, view ini
--       kosong untuk periode itu → komisi historis jadi NOL. Kalau ada sengketa
--       gaji, tidak ada apa pun untuk dirujuk.
--
-- Migrasi ini mengawetkan BASIS-nya (omzet & jumlah order per staf per hari) di
-- rollup harian yang sudah ada — pola yang sama dengan by_payment/by_category,
-- sehingga ikut refresh & cron yang sama, tanpa tabel/cron baru.
--
-- CATATAN LINGKUP — yang TIDAK dilakukan di sini: mengunci nominal komisi saat
-- dibayarkan. Itu keputusan produk (kapan komisi dianggap final? apakah aturan
-- yang berubah boleh mengubah komisi berjalan?), bukan keputusan teknis. Yang
-- ditutup di sini adalah bagian yang TIDAK BISA dibatalkan: hilangnya basis
-- akibat prune. Selama basisnya ada, komisi historis masih bisa direkonstruksi.

ALTER TABLE sales_daily_summary
  ADD COLUMN IF NOT EXISTS by_staff JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN sales_daily_summary.by_staff IS
  'Basis komisi per staf: {staff_id: {"revenue": x, "orders": n}}. revenue sudah '
  'NET refund (cermin v_kasir_performance). Diawetkan agar komisi historis tetap '
  'bisa dihitung setelah order mentahnya dipangkas prune_old_orders.';

-- Salinan setia versi 118 — yang berubah hanya ditandai "◄ 121".
CREATE OR REPLACE FUNCTION public.refresh_sales_daily_summary(
  p_date DATE DEFAULT (current_date - 1)
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  INSERT INTO sales_daily_summary AS s (
    outlet_id, sales_date, order_count, gross, discount, tax, service, net,
    refund, by_payment, by_category,
    by_staff,                                                      -- ◄ 121
    refreshed_at
  )
  SELECT
    o.outlet_id,
    p_date,
    count(DISTINCT o.id),
    coalesce(sum(o.subtotal), 0),
    coalesce(sum(o.discount_amount), 0),
    coalesce(sum(o.tax_amount), 0),
    coalesce(sum(o.service_charge), 0),
    coalesce(sum(o.total_amount), 0) - coalesce(sum(rf.refund), 0),
    coalesce(sum(rf.refund), 0),
    coalesce((
      SELECT jsonb_object_agg(pm.method, pm.amt)
      FROM (
        SELECT pay.method::text AS method, sum(pay.amount) AS amt
        FROM payments pay
        JOIN orders o2 ON o2.id = pay.order_id
        WHERE o2.outlet_id = o.outlet_id
          AND (pay.paid_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
          AND o2.status = 'paid'
        GROUP BY pay.method
      ) pm
    ), '{}'::jsonb),
    coalesce((
      SELECT jsonb_object_agg(cat.category_id, cat.rev)
      FROM (
        SELECT mi.category_id::text AS category_id, sum(oi.subtotal) AS rev
        FROM order_items oi
        JOIN orders o3 ON o3.id = oi.order_id
        JOIN menu_items mi ON mi.id = oi.menu_item_id
        WHERE o3.outlet_id = o.outlet_id
          AND (o3.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
          AND o3.status = 'paid'
          AND mi.category_id IS NOT NULL
        GROUP BY mi.category_id
      ) cat
    ), '{}'::jsonb),
    -- ◄ 121 Basis komisi per staf. Rumus omzet CERMIN v_kasir_performance
    -- (net refund) supaya komisi dari ringkasan = komisi dari view.
    coalesce((
      SELECT jsonb_object_agg(st.kasir_id, jsonb_build_object(
               'revenue', st.revenue, 'orders', st.orders))
      FROM (
        SELECT o4.created_by::text AS kasir_id,
               sum(o4.total_amount - COALESCE(rf4.refund, 0)) AS revenue,
               count(*)                                       AS orders
        FROM orders o4
        LEFT JOIN (
          SELECT order_id, sum(amount) AS refund FROM refunds GROUP BY order_id
        ) rf4 ON rf4.order_id = o4.id
        WHERE o4.outlet_id = o.outlet_id
          AND (o4.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
          AND o4.status = 'paid'
          AND o4.created_by IS NOT NULL
        GROUP BY o4.created_by
      ) st
    ), '{}'::jsonb),
    now()
  FROM orders o
  LEFT JOIN (
    SELECT order_id, sum(amount) AS refund FROM refunds GROUP BY order_id
  ) rf ON rf.order_id = o.id
  WHERE (o.created_at AT TIME ZONE 'Asia/Jakarta')::date = p_date
    AND o.status = 'paid'
  GROUP BY o.outlet_id
  ON CONFLICT (outlet_id, sales_date) DO UPDATE SET
    order_count = EXCLUDED.order_count,
    gross       = EXCLUDED.gross,
    discount    = EXCLUDED.discount,
    tax         = EXCLUDED.tax,
    service     = EXCLUDED.service,
    net         = EXCLUDED.net,
    refund      = EXCLUDED.refund,
    by_payment  = EXCLUDED.by_payment,
    by_category = EXCLUDED.by_category,
    by_staff    = EXCLUDED.by_staff,                               -- ◄ 121
    refreshed_at = now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_sales_daily_summary(DATE) FROM PUBLIC;

-- Backfill: isi by_staff untuk seluruh histori yang masih ada.
DO $$
DECLARE
  d DATE;
  v_days INTEGER := 0;
BEGIN
  FOR d IN
    SELECT DISTINCT (created_at AT TIME ZONE 'Asia/Jakarta')::date
    FROM orders WHERE status = 'paid'
    ORDER BY 1
  LOOP
    PERFORM public.refresh_sales_daily_summary(d);
    v_days := v_days + 1;
  END LOOP;
  RAISE NOTICE '121: basis komisi per staf diawetkan untuk % hari', v_days;
END;
$$;

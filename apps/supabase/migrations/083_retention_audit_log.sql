-- 083_retention_audit_log.sql
-- STRATEGI RETENSI #1 — pangkas order_audit_log (penyumbang pertumbuhan terbesar).
-- Log ini ~3 baris/order, append-only, tak pernah menyusut. Simpan 90 hari,
-- HANYA untuk order yang sudah final (paid/void/cancelled) supaya trail order
-- yang masih aktif tak pernah hilang berapapun umurnya.
-- Aman: order_audit_log hanya dibaca per-order (trail), bukan laporan agregat.

-- ── Fungsi prune (dipakai job terjadwal & bisa dipanggil manual) ─────────────
CREATE OR REPLACE FUNCTION public.prune_order_audit_log(p_keep_days INT DEFAULT 90)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM order_audit_log al
  USING orders o
  WHERE al.order_id = o.id
    AND al.created_at < now() - make_interval(days => p_keep_days)
    AND o.status IN ('paid', 'void', 'cancelled');
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- Hanya service_role/postgres yang boleh memanggil (bukan anon/authenticated).
REVOKE ALL ON FUNCTION public.prune_order_audit_log(INT) FROM PUBLIC;

-- ── Jadwalkan harian 02:10 via pg_cron ──────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- cron.schedule meng-upsert berdasarkan nama job → aman dijalankan ulang.
SELECT cron.schedule(
  'prune-order-audit-log',
  '10 2 * * *',
  $$SELECT public.prune_order_audit_log(90);$$
);

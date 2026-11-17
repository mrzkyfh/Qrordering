-- ============================================================
-- 197 — Broadcast perubahan order tanpa polling WAL
--
-- Aplikasi sebelumnya memakai Postgres Changes `.stream()`. Statistik
-- pg_stat_statements menunjukkan realtime.list_changes dipanggil >1,7 juta
-- kali. Trigger ini mengirim sinyal kecil hanya ketika order benar-benar
-- berubah. Payload tidak memuat data pelanggan dan channel dibuat publik;
-- data order tetap diambil lewat REST/RLS aplikasi setelah sinyal diterima.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.broadcast_order_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet_id uuid;
  v_order_id uuid;
BEGIN
  v_outlet_id := COALESCE(NEW.outlet_id, OLD.outlet_id);
  v_order_id := COALESCE(NEW.id, OLD.id);

  PERFORM realtime.send(
    jsonb_build_object(
      'operation', TG_OP,
      'order_id', v_order_id
    ),
    'change',
    'orders:' || v_outlet_id::text,
    false
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.broadcast_order_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_broadcast_order_change ON public.orders;
CREATE TRIGGER trg_broadcast_order_change
AFTER INSERT OR UPDATE OR DELETE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.broadcast_order_change();

COMMIT;

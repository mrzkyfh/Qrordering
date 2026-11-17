-- ============================================================
-- 198 — Broadcast privat per outlet untuk aplikasi dan dashboard
--
-- Menggantikan listener postgres_changes owner panel yang terus memanggil
-- realtime.list_changes. Klien hanya menerima sinyal kecil, lalu React Query
-- mengambil ulang kelompok laporan yang benar-benar terpengaruh.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.can_receive_outlet_broadcast(p_topic text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = (SELECT auth.uid())
      AND p.is_active = true
      AND split_part(p_topic, ':', 1) IN ('orders', 'dashboard')
      AND (
        p.role = 'owner'
        OR p.outlet_id::text = split_part(p_topic, ':', 2)
      )
  );
$$;

REVOKE ALL ON FUNCTION public.can_receive_outlet_broadcast(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_receive_outlet_broadcast(text) TO authenticated;

DROP POLICY IF EXISTS "outlet members receive private broadcasts"
  ON realtime.messages;
CREATE POLICY "outlet members receive private broadcasts"
ON realtime.messages
FOR SELECT
TO authenticated
USING (
  extension = 'broadcast'
  AND public.can_receive_outlet_broadcast((SELECT realtime.topic()))
);

-- Ubah channel aplikasi kasir menjadi privat. Payload tetap minimal; detail
-- order selalu diambil lewat REST yang dilindungi RLS tabel orders.
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
    true
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.broadcast_order_change() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.broadcast_dashboard_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet_id uuid;
BEGIN
  v_outlet_id := COALESCE(NEW.outlet_id, OLD.outlet_id);

  PERFORM realtime.send(
    jsonb_build_object(
      'operation', TG_OP,
      'table', TG_TABLE_NAME
    ),
    'change',
    'dashboard:' || v_outlet_id::text,
    true
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.broadcast_dashboard_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_dashboard_orders ON public.orders;
CREATE TRIGGER trg_dashboard_orders
AFTER INSERT OR UPDATE OR DELETE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.broadcast_dashboard_change();

DROP TRIGGER IF EXISTS trg_dashboard_payments ON public.payments;
CREATE TRIGGER trg_dashboard_payments
AFTER INSERT OR UPDATE OR DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.broadcast_dashboard_change();

DROP TRIGGER IF EXISTS trg_dashboard_refunds ON public.refunds;
CREATE TRIGGER trg_dashboard_refunds
AFTER INSERT OR UPDATE OR DELETE ON public.refunds
FOR EACH ROW EXECUTE FUNCTION public.broadcast_dashboard_change();

DROP TRIGGER IF EXISTS trg_dashboard_expenses ON public.expenses;
CREATE TRIGGER trg_dashboard_expenses
AFTER INSERT OR UPDATE OR DELETE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION public.broadcast_dashboard_change();

DROP TRIGGER IF EXISTS trg_dashboard_tables ON public.restaurant_tables;
CREATE TRIGGER trg_dashboard_tables
AFTER INSERT OR UPDATE OR DELETE ON public.restaurant_tables
FOR EACH ROW EXECUTE FUNCTION public.broadcast_dashboard_change();

COMMIT;

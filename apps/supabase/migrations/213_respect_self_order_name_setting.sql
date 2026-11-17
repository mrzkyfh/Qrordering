ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_self_order_customer_name_required;

CREATE OR REPLACE FUNCTION public.enforce_self_order_customer_name_setting()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name_required BOOLEAN;
BEGIN
  IF NEW.order_type <> 'self_order' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(o.settings @> '{"self_order_require_name": true}'::JSONB, false)
    INTO v_name_required
  FROM public.outlets o
  WHERE o.id = NEW.outlet_id;

  IF v_name_required AND NULLIF(BTRIM(NEW.customer_name), '') IS NULL THEN
    RAISE EXCEPTION 'Nama pelanggan wajib diisi untuk pesanan online'
      USING ERRCODE = '23514',
            CONSTRAINT = 'orders_self_order_customer_name_required';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_self_order_customer_name_setting()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_self_order_customer_name_insert ON public.orders;
CREATE TRIGGER trg_self_order_customer_name_insert
  BEFORE INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_self_order_customer_name_setting();

DROP TRIGGER IF EXISTS trg_self_order_customer_name_update ON public.orders;
CREATE TRIGGER trg_self_order_customer_name_update
  BEFORE UPDATE OF order_type, customer_name, outlet_id ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_self_order_customer_name_setting();

COMMENT ON FUNCTION public.enforce_self_order_customer_name_setting() IS
  'Nama customer self-order wajib hanya bila self_order_require_name aktif pada outlet.';
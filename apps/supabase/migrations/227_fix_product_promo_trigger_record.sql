-- The same deferred trigger is attached to orders and order_items.  A CASE
-- expression that mentions NEW.order_id is not safe for an orders record:
-- PostgreSQL resolves the record field before the CASE can discard that arm,
-- causing 42703 during every QR checkout.  Branch first, then access only the
-- field that exists on the trigger's table.
CREATE OR REPLACE FUNCTION public.enforce_order_product_promo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
BEGIN
  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'DELETE' THEN
      v_order_id := OLD.id;
    ELSE
      v_order_id := NEW.id;
    END IF;
  ELSIF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'DELETE' THEN
      v_order_id := OLD.order_id;
    ELSE
      v_order_id := NEW.order_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Trigger promo dipasang pada tabel yang tidak didukung: %',
      TG_TABLE_NAME USING ERRCODE = '55000';
  END IF;

  PERFORM public.validate_order_product_promo(v_order_id);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_order_product_promo()
  FROM PUBLIC, anon, authenticated;


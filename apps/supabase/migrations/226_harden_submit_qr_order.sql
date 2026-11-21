-- Keep the public checkout entry point deterministic.  The historical
-- create_self_order API has several overloads; PL/pgSQL + positional dispatch
-- makes the selected signature explicit and also records the real database
-- failure in Postgres logs without returning internal context to the browser.
CREATE OR REPLACE FUNCTION public.submit_qr_order(
  p_outlet_id UUID,
  p_table_id UUID,
  p_items JSONB,
  p_table_token TEXT,
  p_customer_name TEXT,
  p_notes TEXT,
  p_promo_code TEXT,
  p_member_phone TEXT,
  p_request_id UUID,
  p_product_promo_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- These flags only authorize changes made inside this security-definer
  -- transaction.  They are needed by the integrity guards installed after the
  -- original QR-order function was introduced.
  PERFORM set_config('app.order_metadata_mutation', 'on', true);
  PERFORM set_config('app.order_financial_mutation', 'on', true);

  RETURN public.create_self_order(
    p_outlet_id,
    p_table_id,
    p_items,
    p_table_token,
    p_customer_name,
    p_notes,
    p_promo_code,
    p_member_phone,
    p_request_id,
    p_product_promo_id
  );
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'submit_qr_order failed sqlstate=% message=%', SQLSTATE, SQLERRM;
  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_qr_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_qr_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) TO anon, authenticated;


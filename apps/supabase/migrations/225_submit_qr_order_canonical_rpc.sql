-- Stable public checkout endpoint.  create_self_order has historical overloads;
-- exposing one uniquely named signature avoids PostgREST overload ambiguity.
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
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.create_self_order(
    p_outlet_id => p_outlet_id,
    p_table_id => p_table_id,
    p_items => p_items,
    p_table_token => p_table_token,
    p_customer_name => p_customer_name,
    p_notes => p_notes,
    p_promo_code => p_promo_code,
    p_member_phone => p_member_phone,
    p_request_id => p_request_id,
    p_product_promo_id => p_product_promo_id
  );
$$;

REVOKE ALL ON FUNCTION public.submit_qr_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_qr_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) TO anon, authenticated;

COMMENT ON FUNCTION public.submit_qr_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID
) IS 'Canonical public QR checkout endpoint with idempotency and product promo support.';

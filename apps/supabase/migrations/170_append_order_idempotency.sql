-- 170_append_order_idempotency.sql
--
-- Open-bill item additions must be replay-safe. A Wi-Fi timeout can happen
-- after append_order_items committed but before the client received its JSON;
-- the same request_id must then return the original item rows.

CREATE TABLE IF NOT EXISTS public.order_item_append_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  request_id UUID NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (order_id, request_id)
);

REVOKE ALL ON TABLE public.order_item_append_requests FROM PUBLIC, anon, authenticated;

-- Force public clients through the ten-argument idempotent self-order RPC.
-- The nine-argument token wrapper from migration 148 is still used internally
-- by the new function, but must not remain an API-visible overload.
REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER
) FROM PUBLIC, anon, authenticated;

-- The five-argument implementation from migration 141 is kept as an internal
-- helper. It remains atomic; this wrapper adds the durable replay record.
REVOKE ALL ON FUNCTION public.append_order_items(UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.append_order_items(
  p_order_id UUID,
  p_items JSONB,
  p_tax_percent NUMERIC,
  p_tax_active BOOLEAN,
  p_service_charge_percent NUMERIC,
  p_request_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'ID permintaan penambahan item wajib diisi'
      USING ERRCODE = '22023';
  END IF;

  -- Serialize requests for the same order before checking the replay table.
  PERFORM 1 FROM public.orders WHERE id = p_order_id FOR UPDATE;

  SELECT r.result
    INTO v_result
  FROM public.order_item_append_requests r
  WHERE r.order_id = p_order_id
    AND r.request_id = p_request_id;
  IF FOUND THEN
    RETURN v_result;
  END IF;

  v_result := public.append_order_items(
    p_order_id,
    p_items,
    p_tax_percent,
    p_tax_active,
    p_service_charge_percent
  );

  INSERT INTO public.order_item_append_requests(order_id, request_id, result)
  VALUES (p_order_id, p_request_id, v_result);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.append_order_items(
  UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.append_order_items(
  UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC, UUID
) TO authenticated;

COMMENT ON FUNCTION public.append_order_items(
  UUID, JSONB, NUMERIC, BOOLEAN, NUMERIC, UUID
) IS
  'Tambah item open bill secara atomik dan idempoten berdasarkan request_id.';

-- Prevent authenticated clients from changing order line items outside the
-- server-side transaction RPCs. Direct UPDATE/DELETE could otherwise mutate a
-- draft line's quantity/price without recomputing the order financials.
-- The official RPCs are SECURITY DEFINER and continue to manage line items.

DROP POLICY IF EXISTS order_items_update ON public.order_items;
DROP POLICY IF EXISTS order_items_delete ON public.order_items;

REVOKE UPDATE, DELETE ON TABLE public.order_items FROM anon, authenticated;


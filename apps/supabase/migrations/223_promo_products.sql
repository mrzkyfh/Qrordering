-- Produk yang berpartisipasi pada promo. Relasi dikelola melalui RPC agar
-- outlet dan kewenangan selalu diverifikasi di server.
CREATE TABLE IF NOT EXISTS public.promo_products (
  promo_id UUID NOT NULL REFERENCES public.promos(id) ON DELETE CASCADE,
  menu_item_id UUID NOT NULL REFERENCES public.menu_items(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (promo_id, menu_item_id)
);
CREATE INDEX IF NOT EXISTS idx_promo_products_menu_item ON public.promo_products(menu_item_id, promo_id);
ALTER TABLE public.promo_products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promo_products_select ON public.promo_products;
CREATE POLICY promo_products_select ON public.promo_products
FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.promos promo
    JOIN public.profiles actor ON actor.id = auth.uid()
    WHERE promo.id = promo_products.promo_id AND actor.is_active
      AND (actor.role = 'owner' OR actor.outlet_id = promo.outlet_id)
  )
);
REVOKE ALL ON TABLE public.promo_products FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.promo_products TO authenticated;

CREATE OR REPLACE FUNCTION public.set_promo_products(p_promo_id UUID, p_menu_item_ids UUID[])
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_outlet UUID;
  v_role public.user_role;
  v_actor_outlet UUID;
  v_count INTEGER;
BEGIN
  SELECT role, outlet_id INTO v_role, v_actor_outlet
  FROM public.profiles WHERE id = auth.uid() AND is_active;
  SELECT outlet_id INTO v_outlet FROM public.promos WHERE id = p_promo_id FOR UPDATE;
  IF v_outlet IS NULL THEN RAISE EXCEPTION 'Promo tidak ditemukan' USING ERRCODE = 'P0002'; END IF;
  IF v_role NOT IN ('owner', 'admin', 'manajer')
     OR (v_role <> 'owner' AND v_actor_outlet IS DISTINCT FROM v_outlet) THEN
    RAISE EXCEPTION 'Tidak berwenang mengubah produk promo' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_menu_item_ids, ARRAY[]::UUID[])) id
    LEFT JOIN public.menu_items item ON item.id = id AND item.outlet_id = v_outlet
    WHERE item.id IS NULL
  ) THEN
    RAISE EXCEPTION 'Produk promo berasal dari outlet lain atau tidak ditemukan' USING ERRCODE = '23514';
  END IF;
  DELETE FROM public.promo_products WHERE promo_id = p_promo_id;
  INSERT INTO public.promo_products(promo_id, menu_item_id)
  SELECT p_promo_id, id FROM unnest(COALESCE(p_menu_item_ids, ARRAY[]::UUID[])) id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.set_promo_products(UUID, UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_promo_products(UUID, UUID[]) TO authenticated;

COMMENT ON TABLE public.promo_products IS 'Daftar produk yang ikut pada sebuah promo; kosong berarti promo tidak dibatasi ke produk tertentu.';

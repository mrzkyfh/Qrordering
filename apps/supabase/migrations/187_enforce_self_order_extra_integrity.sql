-- Enforce menu-extra integrity for self-order, POS, open-bill edits, and
-- offline replay. Client validation is only UX; all price and selection rules
-- remain authoritative here.

CREATE OR REPLACE FUNCTION public._self_order_line(
  p_outlet_id UUID,
  p_item JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_menu_item_id UUID;
  v_base_price NUMERIC;
  v_options JSONB := '[]'::JSONB;
  v_option_count INTEGER := 0;
  v_matched_option_count INTEGER := 0;
  v_extra_total NUMERIC := 0;
BEGIN
  IF p_item IS NULL OR jsonb_typeof(p_item) <> 'object' THEN
    RAISE EXCEPTION 'Item pesanan tidak valid';
  END IF;

  BEGIN
    v_menu_item_id := NULLIF(BTRIM(p_item->>'menu_item_id'), '')::UUID;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Menu tidak valid';
  END;

  IF v_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'Menu tidak valid';
  END IF;

  SELECT mi.price
    INTO v_base_price
  FROM public.menu_items mi
  WHERE mi.id = v_menu_item_id
    AND mi.outlet_id = p_outlet_id
    AND mi.is_active = TRUE
    AND mi.is_available = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Menu tidak tersedia';
  END IF;

  IF p_item ? 'options' THEN
    IF jsonb_typeof(p_item->'options') <> 'array' THEN
      RAISE EXCEPTION 'Pilihan tambahan tidak valid';
    END IF;
    v_options := p_item->'options';
  END IF;

  v_option_count := jsonb_array_length(v_options);
  IF v_option_count > 30 THEN
    RAISE EXCEPTION 'Pilihan tambahan terlalu banyak';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_options) option_payload
    GROUP BY option_payload->>'menu_extra_option_id'
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan duplikat';
  END IF;

  BEGIN
    SELECT COUNT(*), COALESCE(SUM(meo.price), 0)
      INTO v_matched_option_count, v_extra_total
    FROM jsonb_array_elements(v_options) option_payload
    JOIN public.menu_extra_options meo
      ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
    JOIN public.menu_extras me
      ON me.id = meo.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    JOIN public.menu_item_extras mie
      ON mie.extra_id = me.id
     AND mie.menu_item_id = v_menu_item_id;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak valid';
  END;

  IF v_matched_option_count <> v_option_count THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak tersedia untuk menu ini';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_item_extras mie
    JOIN public.menu_extras me
      ON me.id = mie.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    WHERE mie.menu_item_id = v_menu_item_id
      AND me.type = 'required'
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_options) option_payload
        JOIN public.menu_extra_options meo
          ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
        WHERE meo.extra_id = me.id
      )
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan wajib belum dipilih';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_options) option_payload
    JOIN public.menu_extra_options meo
      ON meo.id = NULLIF(BTRIM(option_payload->>'menu_extra_option_id'), '')::UUID
    JOIN public.menu_extras me
      ON me.id = meo.extra_id
     AND me.outlet_id = p_outlet_id
     AND me.is_active = TRUE
    JOIN public.menu_item_extras mie
      ON mie.extra_id = me.id
     AND mie.menu_item_id = v_menu_item_id
    WHERE me.selection_type = 'single'
    GROUP BY me.id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan tunggal hanya boleh dipilih satu';
  END IF;

  RETURN v_base_price + v_extra_total;
END;
$$;

REVOKE ALL ON FUNCTION public._self_order_line(UUID, JSONB) FROM PUBLIC;

-- Keep every order bounded even when a trusted RPC or an offline replay sends
-- a malformed payload. The UI applies the same limits, but server limits are
-- authoritative and also prevent one request from creating an excessive
-- number of rows. Deliberately do not validate order_id updates so legitimate
-- order merge/move workflows keep working for historical orders.
CREATE OR REPLACE FUNCTION public.enforce_order_item_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.quantity < 1 OR NEW.quantity > 100 THEN
    RAISE EXCEPTION 'Jumlah item harus antara 1 dan 100'
      USING ERRCODE = '22023';
  END IF;

  IF TG_OP = 'INSERT' AND (
    SELECT COUNT(*)
    FROM public.order_items oi
    WHERE oi.order_id = NEW.order_id
  ) >= 50 THEN
    RAISE EXCEPTION 'Maksimal 50 jenis item per pesanan'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_order_item_limits()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_enforce_order_item_limits
  ON public.order_items;
CREATE TRIGGER trg_enforce_order_item_limits
BEFORE INSERT OR UPDATE OF quantity ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION public.enforce_order_item_limits();

-- Snapshot labels and prices must also be canonical when another trusted path
-- inserts order_item_options directly. This prevents forged report/receipt text.
CREATE OR REPLACE FUNCTION public.canonicalize_order_item_option()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_menu_extra_id UUID;
  v_extra_name TEXT;
  v_option_name TEXT;
  v_price NUMERIC;
BEGIN
  SELECT me.id, me.name, meo.name, meo.price
    INTO v_menu_extra_id, v_extra_name, v_option_name, v_price
  FROM public.order_items oi
  JOIN public.menu_items mi
    ON mi.id = oi.menu_item_id
  JOIN public.menu_item_extras mie
    ON mie.menu_item_id = oi.menu_item_id
  JOIN public.menu_extras me
    ON me.id = mie.extra_id
   AND me.outlet_id = mi.outlet_id
   AND me.is_active = TRUE
  JOIN public.menu_extra_options meo
    ON meo.extra_id = me.id
   AND meo.id = NEW.menu_extra_option_id
  WHERE oi.id = NEW.order_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak tersedia untuk item pesanan ini';
  END IF;

  NEW.menu_extra_id := v_menu_extra_id;
  NEW.extra_name := v_extra_name;
  NEW.option_name := v_option_name;
  NEW.price := v_price;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.canonicalize_order_item_option() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_canonicalize_order_item_option
  ON public.order_item_options;
CREATE TRIGGER trg_canonicalize_order_item_option
BEFORE INSERT OR UPDATE ON public.order_item_options
FOR EACH ROW
EXECUTE FUNCTION public.canonicalize_order_item_option();

-- Validate the final option set, not each intermediate insert. POS and edit
-- RPCs insert the order item first and its options afterwards, so an immediate
-- required-option check would reject a valid transaction too early.
CREATE OR REPLACE FUNCTION public.validate_order_item_extra_integrity(
  p_order_item_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_menu_item_id UUID;
  v_outlet_id UUID;
  v_option_count INTEGER;
BEGIN
  SELECT oi.menu_item_id, mi.outlet_id
    INTO v_menu_item_id, v_outlet_id
  FROM public.order_items oi
  JOIN public.menu_items mi ON mi.id = oi.menu_item_id
  WHERE oi.id = p_order_item_id;

  -- Deleting an order item cascades to its option snapshots. Once the parent
  -- item no longer exists there is nothing left to validate.
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COUNT(*)
    INTO v_option_count
  FROM public.order_item_options oio
  WHERE oio.order_item_id = p_order_item_id;

  IF v_option_count > 30 THEN
    RAISE EXCEPTION 'Pilihan tambahan terlalu banyak'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_item_options oio
    WHERE oio.order_item_id = p_order_item_id
    GROUP BY oio.menu_extra_option_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan duplikat'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_item_options oio
    WHERE oio.order_item_id = p_order_item_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.menu_extra_options meo
        JOIN public.menu_extras me
          ON me.id = meo.extra_id
         AND me.outlet_id = v_outlet_id
         AND me.is_active = TRUE
        JOIN public.menu_item_extras mie
          ON mie.extra_id = me.id
         AND mie.menu_item_id = v_menu_item_id
        WHERE meo.id = oio.menu_extra_option_id
      )
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan tidak tersedia untuk item pesanan ini'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_item_extras mie
    JOIN public.menu_extras me
      ON me.id = mie.extra_id
     AND me.outlet_id = v_outlet_id
     AND me.is_active = TRUE
    WHERE mie.menu_item_id = v_menu_item_id
      AND me.type = 'required'
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_item_options oio
        JOIN public.menu_extra_options meo
          ON meo.id = oio.menu_extra_option_id
        WHERE oio.order_item_id = p_order_item_id
          AND meo.extra_id = me.id
      )
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan wajib belum dipilih'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_item_options oio
    JOIN public.menu_extra_options meo
      ON meo.id = oio.menu_extra_option_id
    JOIN public.menu_extras me
      ON me.id = meo.extra_id
     AND me.outlet_id = v_outlet_id
     AND me.is_active = TRUE
    WHERE oio.order_item_id = p_order_item_id
      AND me.selection_type = 'single'
    GROUP BY me.id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Pilihan tambahan tunggal hanya boleh dipilih satu'
      USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_order_item_extra_integrity(UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_order_item_extra_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row JSONB;
  v_order_item_id UUID;
BEGIN
  v_row := to_jsonb(NEW);
  v_order_item_id := NULLIF(
    COALESCE(v_row->>'order_item_id', v_row->>'id'),
    ''
  )::UUID;
  PERFORM public.validate_order_item_extra_integrity(v_order_item_id);
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_order_item_extra_integrity()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_order_item_extra_integrity_from_item
  ON public.order_items;
-- Re-check a row only when it is created or its menu changes. Operational
-- updates such as void/refund must not be rejected merely because the catalog
-- gained a new required extra after the historical sale was recorded.
CREATE CONSTRAINT TRIGGER trg_order_item_extra_integrity_from_item
AFTER INSERT OR UPDATE OF menu_item_id ON public.order_items
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.enforce_order_item_extra_integrity();

DROP TRIGGER IF EXISTS trg_order_item_extra_integrity_from_option
  ON public.order_item_options;
-- Deliberately exclude DELETE. Catalog maintenance can cascade-delete an old
-- option snapshot while the historical order item remains. Re-validating that
-- old sale against today's required groups would block legitimate catalog
-- cleanup. Transaction creation/edit paths are still covered by INSERT/UPDATE
-- here and by the deferred order_items trigger above.
CREATE CONSTRAINT TRIGGER trg_order_item_extra_integrity_from_option
AFTER INSERT OR UPDATE ON public.order_item_options
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.enforce_order_item_extra_integrity();

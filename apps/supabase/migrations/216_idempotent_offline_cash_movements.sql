-- 216_idempotent_offline_cash_movements.sql
--
-- Kas Masuk/Keluar yang dibuat tanpa internet memakai request UUID tetap.
-- Advisory lock + unique index membuat timeout/retry aman dari pencatatan kas
-- dan expense ganda. Identitas meja maupun URL/token QR tidak disentuh.

ALTER TABLE public.cash_movements
  ADD COLUMN IF NOT EXISTS request_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_movements_request_id_unique
  ON public.cash_movements(request_id)
  WHERE request_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.record_cash_movement_idempotent(
  p_request_id UUID,
  p_shift_id UUID,
  p_outlet_id UUID,
  p_type TEXT,
  p_amount NUMERIC,
  p_note TEXT,
  p_expense_category TEXT,
  p_created_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_catalog
AS $$
DECLARE
  v_existing public.cash_movements%ROWTYPE;
  v_result JSONB;
  v_movement_id UUID;
  v_expense_id UUID;
  v_shift_started_at TIMESTAMPTZ;
  v_normalized_note TEXT := NULLIF(btrim(p_note), '');
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer') THEN
    RAISE EXCEPTION
      'Kas Masuk/Keluar hanya dapat dicatat oleh Owner, Admin, atau Manajer'
      USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL OR p_shift_id IS NULL OR p_outlet_id IS NULL THEN
    RAISE EXCEPTION 'Identitas pergerakan kas tidak lengkap'
      USING ERRCODE = '22023';
  END IF;
  IF p_created_at IS NULL
     OR p_created_at < now() - interval '7 days'
     OR p_created_at > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu pergerakan kas tidak valid'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_request_id::TEXT, 216)
  );

  SELECT * INTO v_existing
  FROM public.cash_movements
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing.shift_id IS DISTINCT FROM p_shift_id
       OR v_existing.outlet_id IS DISTINCT FROM p_outlet_id
       OR v_existing.type IS DISTINCT FROM p_type
       OR v_existing.amount IS DISTINCT FROM p_amount
       OR v_existing.note IS DISTINCT FROM v_normalized_note
       OR v_existing.created_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Request pergerakan kas telah dipakai dengan data berbeda'
        USING ERRCODE = '22023';
    END IF;
    SELECT id INTO v_expense_id
    FROM public.expenses
    WHERE cash_movement_id = v_existing.id;
    RETURN to_jsonb(v_existing) || jsonb_build_object(
      'expense_id', v_expense_id
    );
  END IF;

  SELECT start_time INTO v_shift_started_at
  FROM public.shifts
  WHERE id = p_shift_id AND outlet_id = p_outlet_id;
  IF NOT FOUND OR p_created_at < v_shift_started_at THEN
    RAISE EXCEPTION 'Waktu pergerakan kas berada di luar shift'
      USING ERRCODE = '22023';
  END IF;

  v_result := public.record_cash_movement_management_impl(
    p_shift_id,
    p_outlet_id,
    p_type,
    p_amount,
    p_note,
    p_expense_category
  );
  v_movement_id := (v_result ->> 'id')::UUID;

  UPDATE public.cash_movements
  SET request_id = p_request_id,
      created_at = p_created_at
  WHERE id = v_movement_id
  RETURNING * INTO v_existing;

  IF p_type = 'out' THEN
    UPDATE public.expenses
    SET expense_date = (p_created_at AT TIME ZONE 'Asia/Jakarta')::DATE
    WHERE cash_movement_id = v_movement_id
    RETURNING id INTO v_expense_id;
  END IF;

  RETURN to_jsonb(v_existing) || jsonb_build_object(
    'expense_id', v_expense_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_cash_movement_idempotent(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_movement_idempotent(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, TIMESTAMPTZ
) TO authenticated;

COMMENT ON FUNCTION public.record_cash_movement_idempotent(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, TEXT, TIMESTAMPTZ
) IS
  'Kas Masuk/Keluar idempoten untuk outbox offline; retry tidak menggandakan cash movement atau expense.';

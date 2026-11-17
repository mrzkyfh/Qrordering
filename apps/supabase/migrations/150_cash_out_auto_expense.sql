-- 150_cash_out_auto_expense.sql
-- Satu input Kas Keluar menghasilkan dua catatan dalam satu transaksi:
--   1. cash_movements untuk rekonsiliasi uang fisik di laci kasir;
--   2. expenses untuk laporan pengeluaran dan laba rugi.
--
-- Catatan lama tidak diisi ulang karena sebagian mungkin sudah dicatat manual.
-- Pengisian ulang berisiko menggandakan pengeluaran historis.

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS cash_movement_id UUID
  REFERENCES public.cash_movements(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_expenses_cash_movement_unique
  ON public.expenses(cash_movement_id)
  WHERE cash_movement_id IS NOT NULL;

COMMENT ON COLUMN public.expenses.cash_movement_id IS
  'Sumber Kas Keluar yang otomatis membuat pengeluaran. NULL untuk input manual.';

-- Implementasi utama dengan kategori pengeluaran.
CREATE OR REPLACE FUNCTION public.record_cash_movement(
  p_shift_id UUID,
  p_outlet_id UUID,
  p_type TEXT,
  p_amount NUMERIC,
  p_note TEXT,
  p_expense_category TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_movement public.cash_movements%ROWTYPE;
  v_expense_id UUID;
  v_category public.expense_category;
BEGIN
  IF COALESCE(public.auth_role()::TEXT, '') NOT IN
       ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang mencatat pergerakan kas'
      USING ERRCODE = '42501';
  END IF;
  IF p_shift_id IS NULL OR p_outlet_id IS NULL THEN
    RAISE EXCEPTION 'Shift dan outlet wajib diisi' USING ERRCODE = '22023';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('in', 'out') THEN
    RAISE EXCEPTION 'Jenis pergerakan kas tidak valid' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Nominal pergerakan kas harus lebih besar dari nol'
      USING ERRCODE = '22023';
  END IF;

  IF p_type = 'out' THEN
    IF COALESCE(p_expense_category, '') NOT IN (
      'bahan_baku', 'operasional', 'gaji',
      'peralatan', 'marketing', 'lain_lain'
    ) THEN
      RAISE EXCEPTION 'Kategori pengeluaran tidak valid'
        USING ERRCODE = '22023';
    END IF;
    v_category := p_expense_category::public.expense_category;
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM p_outlet_id THEN
    RAISE EXCEPTION 'Shift tidak ditemukan di outlet tersebut'
      USING ERRCODE = '42501';
  END IF;
  IF v_shift.end_time IS NOT NULL THEN
    RAISE EXCEPTION 'Shift sudah ditutup' USING ERRCODE = '22023';
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND v_shift.outlet_id IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Tidak berwenang atas shift ini' USING ERRCODE = '42501';
  END IF;
  IF public.auth_role() = 'kasir'
     AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya dapat mencatat kas pada shift miliknya'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.cash_movements(
    shift_id, outlet_id, type, amount, note, created_by
  ) VALUES (
    p_shift_id, p_outlet_id, p_type, p_amount,
    NULLIF(btrim(p_note), ''), auth.uid()
  )
  RETURNING * INTO v_movement;

  IF p_type = 'out' THEN
    INSERT INTO public.expenses(
      outlet_id,
      category,
      amount,
      description,
      expense_date,
      created_by,
      cash_movement_id
    ) VALUES (
      p_outlet_id,
      v_category,
      p_amount,
      COALESCE(NULLIF(btrim(p_note), ''), 'Kas keluar dari laci kasir'),
      (now() AT TIME ZONE 'Asia/Jakarta')::date,
      auth.uid(),
      v_movement.id
    )
    RETURNING id INTO v_expense_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_movement.id,
    'shift_id', v_movement.shift_id,
    'outlet_id', v_movement.outlet_id,
    'type', v_movement.type,
    'amount', v_movement.amount,
    'note', v_movement.note,
    'created_by', v_movement.created_by,
    'created_at', v_movement.created_at,
    'expense_id', v_expense_id
  );
END;
$$;

-- Kompatibilitas aplikasi lama: Kas Keluar tanpa kategori tetap dicatat
-- otomatis sebagai kategori Operasional.
CREATE OR REPLACE FUNCTION public.record_cash_movement(
  p_shift_id UUID,
  p_outlet_id UUID,
  p_type TEXT,
  p_amount NUMERIC,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
  SELECT public.record_cash_movement(
    p_shift_id,
    p_outlet_id,
    p_type,
    p_amount,
    p_note,
    'operasional'
  );
$$;

REVOKE ALL ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) TO authenticated;

REVOKE ALL ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.record_cash_movement(
  UUID, UUID, TEXT, NUMERIC, TEXT, TEXT
) IS
  'Mencatat Kas Masuk/Keluar. Kas Keluar otomatis membuat expenses pada outlet, '
  'tanggal, kategori, nominal, dan pembuat yang sama dalam satu transaksi.';

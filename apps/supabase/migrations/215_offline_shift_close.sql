-- 215_offline_shift_close.sql
--
-- Penutupan shift yang dibuat saat offline harus aman diputar ulang setelah
-- timeout. RPC ini mengembalikan laporan yang sama bila request pertama sudah
-- berhasil, tetapi responsnya tidak sampai ke perangkat. Waktu tutup dari
-- perangkat dibatasi ketat dan URL/token QR sama sekali tidak disentuh.

CREATE OR REPLACE FUNCTION public.close_shift_idempotent_with_report(
  p_shift_id UUID,
  p_closing_cash NUMERIC,
  p_notes TEXT DEFAULT NULL,
  p_closed_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_closed_at TIMESTAMPTZ := COALESCE(p_closed_at, clock_timestamp());
BEGIN
  IF p_shift_id IS NULL OR p_closing_cash IS NULL OR p_closing_cash < 0 THEN
    RAISE EXCEPTION 'Data penutupan shift tidak valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF NOT (
    COALESCE(public.is_owner(), false)
    OR (
      v_shift.outlet_id = public.auth_outlet_id()
      AND v_role IN ('admin', 'manajer')
    )
    OR (
      v_shift.outlet_id = public.auth_outlet_id()
      AND v_role = 'kasir'
      AND v_shift.kasir_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'Tidak berizin menutup shift ini'
      USING ERRCODE = '42501';
  END IF;

  -- Retry request yang sudah berhasil tidak boleh menghitung/menutup ulang.
  IF v_shift.end_time IS NOT NULL THEN
    IF v_shift.closing_cash IS DISTINCT FROM p_closing_cash THEN
      RAISE EXCEPTION 'Shift sudah ditutup dengan nominal berbeda'
        USING ERRCODE = '22023';
    END IF;
    RETURN public.get_shift_close_report(p_shift_id);
  END IF;

  IF v_closed_at < v_shift.start_time
     OR v_closed_at < clock_timestamp() - interval '7 days'
     OR v_closed_at > clock_timestamp() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu penutupan shift perangkat tidak valid'
      USING ERRCODE = '22023';
  END IF;

  -- Fungsi otoritatif tetap menghitung expected_cash dari data server.
  PERFORM public.close_shift(p_shift_id, p_closing_cash, p_notes);
  UPDATE public.shifts
  SET end_time = v_closed_at
  WHERE id = p_shift_id;

  RETURN public.get_shift_close_report(p_shift_id);
END;
$$;

REVOKE ALL ON FUNCTION public.close_shift_idempotent_with_report(
  UUID, NUMERIC, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_shift_idempotent_with_report(
  UUID, NUMERIC, TEXT, TIMESTAMPTZ
) TO authenticated;

COMMENT ON FUNCTION public.close_shift_idempotent_with_report(
  UUID, NUMERIC, TEXT, TIMESTAMPTZ
) IS
  'Tutup shift secara idempoten untuk replay offline; perhitungan kas tetap dilakukan server.';

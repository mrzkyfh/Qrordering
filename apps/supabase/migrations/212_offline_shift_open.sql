-- 212_offline_shift_open.sql
--
-- Pembukaan till memakai UUID dari perangkat agar aman diulang setelah
-- timeout. Ini memungkinkan kasir membuka shift dari paket cabang lokal saat
-- internet putus; order yang memakai shift tersebut baru dikirim setelah RPC
-- ini berhasil. URL/token QR meja tidak disentuh.

CREATE OR REPLACE FUNCTION public.open_shift_idempotent(
  p_shift_id UUID,
  p_outlet_id UUID,
  p_kasir_id UUID,
  p_opening_cash NUMERIC,
  p_started_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_role TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_started_at TIMESTAMPTZ := COALESCE(p_started_at, clock_timestamp());
BEGIN
  IF p_shift_id IS NULL OR p_outlet_id IS NULL OR p_kasir_id IS NULL THEN
    RAISE EXCEPTION 'ID shift, outlet, dan kasir wajib diisi'
      USING ERRCODE = '22023';
  END IF;
  IF p_opening_cash IS NULL OR p_opening_cash < 0 THEN
    RAISE EXCEPTION 'Modal awal tidak boleh negatif'
      USING ERRCODE = '22023';
  END IF;
  IF v_started_at > clock_timestamp() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Waktu buka shift perangkat terlalu jauh di masa depan'
      USING ERRCODE = '22023';
  END IF;
  IF v_started_at < clock_timestamp() - interval '7 days' THEN
    RAISE EXCEPTION 'Pembukaan shift offline sudah terlalu lama'
      USING ERRCODE = '22023';
  END IF;
  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang membuka shift'
      USING ERRCODE = '42501';
  END IF;
  IF NOT COALESCE(public.is_owner(), false)
     AND p_outlet_id IS DISTINCT FROM public.auth_outlet_id() THEN
    RAISE EXCEPTION 'Tidak berwenang membuka shift outlet ini'
      USING ERRCODE = '42501';
  END IF;
  -- Sama dengan policy shifts_insert: admin boleh membuka shift staf outlet;
  -- role lainnya hanya dapat membuka shift atas identitasnya sendiri.
  IF NOT COALESCE(public.is_owner(), false)
     AND v_role <> 'admin'
     AND p_kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Staf hanya dapat membuka shift miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id;

  IF FOUND THEN
    IF v_shift.outlet_id IS DISTINCT FROM p_outlet_id
       OR v_shift.kasir_id IS DISTINCT FROM p_kasir_id
       OR v_shift.opening_cash IS DISTINCT FROM p_opening_cash THEN
      RAISE EXCEPTION 'ID shift pernah dipakai dengan data berbeda'
        USING ERRCODE = '22023';
    END IF;
    RETURN to_jsonb(v_shift);
  END IF;

  INSERT INTO public.shifts(
    id, outlet_id, kasir_id, start_time, opening_cash
  ) VALUES (
    p_shift_id, p_outlet_id, p_kasir_id, v_started_at, p_opening_cash
  )
  RETURNING * INTO v_shift;

  RETURN to_jsonb(v_shift);
EXCEPTION
  WHEN unique_violation THEN
    -- UUID yang sama mungkin berhasil pada request sebelumnya dan responsnya
    -- hilang. Hanya kasus itu yang idempoten; bentrok shift aktif lain tetap
    -- diteruskan sebagai 23505 agar aplikasi menampilkan sesi yang benar.
    SELECT * INTO v_shift
    FROM public.shifts
    WHERE id = p_shift_id;
    IF FOUND
       AND v_shift.outlet_id IS NOT DISTINCT FROM p_outlet_id
       AND v_shift.kasir_id IS NOT DISTINCT FROM p_kasir_id
       AND v_shift.opening_cash IS NOT DISTINCT FROM p_opening_cash THEN
      RETURN to_jsonb(v_shift);
    END IF;
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.open_shift_idempotent(
  UUID, UUID, UUID, NUMERIC, TIMESTAMPTZ
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_shift_idempotent(
  UUID, UUID, UUID, NUMERIC, TIMESTAMPTZ
) TO authenticated;

COMMENT ON FUNCTION public.open_shift_idempotent(
  UUID, UUID, UUID, NUMERIC, TIMESTAMPTZ
) IS
  'Membuka shift dengan UUID perangkat secara idempoten untuk replay transaksi offline.';

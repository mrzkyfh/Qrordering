-- 143_cash_movement_time_integrity.sql
-- Menutup dua jalur manipulasi yang masih tersisa setelah hardening transaksi:
--   1. cash_movements tidak lagi ditulis langsung dari REST/mobile.
--   2. order/payment tidak boleh diberi timestamp masa depan yang merusak
--      laporan, shift, dan urutan transaksi.

-- ── 1. Kas masuk/keluar harus melalui RPC tervalidasi ───────────────────────
-- Policy 088 hanya memeriksa outlet_id dan created_by. Karena itu request sah
-- masih dapat menunjuk shift outlet lain, shift yang sudah ditutup, atau
-- mengirim nominal yang tidak sesuai konteks kasir.
CREATE OR REPLACE FUNCTION public.record_cash_movement(
  p_shift_id UUID,
  p_outlet_id UUID,
  p_type TEXT,
  p_amount NUMERIC,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_movement public.cash_movements%ROWTYPE;
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
  IF public.auth_role() = 'kasir' AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
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

  RETURN jsonb_build_object(
    'id', v_movement.id,
    'shift_id', v_movement.shift_id,
    'outlet_id', v_movement.outlet_id,
    'type', v_movement.type,
    'amount', v_movement.amount,
    'note', v_movement.note,
    'created_by', v_movement.created_by,
    'created_at', v_movement.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_cash_movement(UUID, UUID, TEXT, NUMERIC, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_movement(UUID, UUID, TEXT, NUMERIC, TEXT)
  TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.cash_movements FROM anon, authenticated;

COMMENT ON FUNCTION public.record_cash_movement(UUID, UUID, TEXT, NUMERIC, TEXT) IS
  'Catat kas masuk/keluar secara atomik: validasi role aktif, outlet, shift terbuka, '
  'nominal, dan actor dilakukan di server (143).';

-- ── 1b. Tutup shift: lock harus dilakukan sebelum membaca semua komponen kas ─
-- Versi 119 menghitung cash_movements lebih dulu, baru mengunci shifts. Pada
-- request bersamaan, kas movement dapat masuk setelah agregasi tetapi sebelum
-- shift ditutup sehingga expected_cash menjadi kurang/lebih dari kondisi nyata.
CREATE OR REPLACE FUNCTION public.close_shift(
  p_shift_id UUID,
  p_closing_cash NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_cash_total NUMERIC := 0;
  v_movement_net NUMERIC := 0;
  v_expected_cash NUMERIC := 0;
  v_cash_difference NUMERIC := 0;
BEGIN
  IF p_closing_cash IS NULL OR p_closing_cash < 0 THEN
    RAISE EXCEPTION 'Uang penutupan shift tidak valid' USING ERRCODE = '22023';
  END IF;

  -- Lock sebelum agregasi. record_cash_movement memakai lock yang sama.
  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_shift.end_time IS NOT NULL THEN
    RAISE EXCEPTION 'shift already closed' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE o.shift_id = p_shift_id
    AND o.status = 'paid'
    AND p.method = 'cash';

  SELECT COALESCE(SUM(CASE WHEN cm.type = 'in' THEN cm.amount ELSE -cm.amount END), 0)
    INTO v_movement_net
  FROM public.cash_movements cm
  WHERE cm.shift_id = p_shift_id;

  v_expected_cash := v_shift.opening_cash + v_cash_total + v_movement_net;
  v_cash_difference := p_closing_cash - v_expected_cash;

  UPDATE public.shifts
  SET end_time = NOW(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

COMMENT ON FUNCTION public.close_shift(UUID, NUMERIC, TEXT) IS
  'Tutup shift dengan mengunci header lebih dulu, lalu menghitung penjualan cash '
  'dan cash_movements secara konsisten (143).';

-- ── 1c. Shift tidak boleh mengikat staf lintas outlet/nonaktif ──────────────
-- Policy lama memvalidasi outlet pada baris shift, tetapi tidak memvalidasi
-- profiles.kasir_id. Admin yang mengirim REST langsung masih dapat membuat
-- shift outlet A dengan kasir yang terdaftar di outlet B atau sudah nonaktif.
CREATE OR REPLACE FUNCTION public.guard_shift_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_role public.user_role;
  v_profile_outlet UUID;
  v_active BOOLEAN;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.outlets
    WHERE id = NEW.outlet_id AND is_active
  ) THEN
    RAISE EXCEPTION 'Outlet shift tidak aktif atau tidak ditemukan'
      USING ERRCODE = '22023';
  END IF;

  SELECT role, outlet_id, is_active
    INTO v_role, v_profile_outlet, v_active
  FROM public.profiles
  WHERE id = NEW.kasir_id;

  IF NOT FOUND OR NOT COALESCE(v_active, false) THEN
    RAISE EXCEPTION 'Kasir shift tidak ditemukan atau tidak aktif'
      USING ERRCODE = '22023';
  END IF;

  -- Owner boleh mengelola lintas outlet; staf lain harus berada di outlet
  -- yang sama dengan shift.
  IF v_role <> 'owner'
     AND v_profile_outlet IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Kasir shift bukan milik outlet tersebut'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_shift_assignment ON public.shifts;
CREATE TRIGGER trg_guard_shift_assignment
  BEFORE INSERT OR UPDATE OF outlet_id, kasir_id, opening_cash
  ON public.shifts
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_shift_assignment();

COMMENT ON FUNCTION public.guard_shift_assignment() IS
  'Memastikan kasir shift aktif dan berada di outlet yang sama; owner dapat '
  'mengelola lintas outlet (143).';

-- ── 2. Tolak timestamp masa depan ──────────────────────────────────────────
-- Tanggal lampau tetap diterima karena sinkronisasi offline memang dapat tiba
-- setelah transaksi terjadi. Hanya jam masa depan yang dibatasi dengan toleransi
-- kecil untuk perbedaan jam perangkat/server.
CREATE OR REPLACE FUNCTION public.guard_future_transaction_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'orders'
     AND NEW.created_at > now() + INTERVAL '5 minutes' THEN
    RAISE EXCEPTION 'Waktu order tidak boleh lebih dari 5 menit di masa depan'
      USING ERRCODE = '22023';
  END IF;

  IF TG_TABLE_NAME = 'payments'
     AND NEW.paid_at > now() + INTERVAL '5 minutes' THEN
    RAISE EXCEPTION 'Waktu pembayaran tidak boleh lebih dari 5 menit di masa depan'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_order_future_timestamp ON public.orders;
CREATE TRIGGER trg_guard_order_future_timestamp
  BEFORE INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_future_transaction_timestamp();

DROP TRIGGER IF EXISTS trg_guard_payment_future_timestamp ON public.payments;
CREATE TRIGGER trg_guard_payment_future_timestamp
  BEFORE INSERT ON public.payments
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_future_transaction_timestamp();

COMMENT ON FUNCTION public.guard_future_transaction_timestamp() IS
  'Mencegah order/pembayaran bertimestamp masa depan; timestamp lampau untuk '
  'offline sync tetap diperbolehkan (143).';

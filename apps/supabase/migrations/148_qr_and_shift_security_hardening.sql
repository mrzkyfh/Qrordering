-- 148_qr_and_shift_security_hardening.sql
--
-- Menutup dua jalur bypass yang masih tersisa:
--   1. create_self_order dulu menerima table_id + outlet_id tanpa membuktikan
--      bahwa pemanggil memegang qr_token meja tersebut. Lock meja sekaligus
--      membuat pemeriksaan anti-spam di fungsi lama serial per meja.
--   2. shift/till pada order dan pembayaran tunai harus masih terbuka, berasal
--      dari outlet order, dan (untuk kasir/manajer) dimiliki pengguna aktif.

CREATE OR REPLACE FUNCTION public.create_self_order(
  p_outlet_id     UUID,
  p_table_id      UUID,
  p_items         JSONB,
  p_table_token   TEXT,
  p_customer_name TEXT    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_promo_code    TEXT    DEFAULT NULL,
  p_member_id     UUID    DEFAULT NULL,
  p_redeem_points INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table_id UUID;
BEGIN
  -- Row lock ini ditahan sampai transaksi selesai. Selain memvalidasi capability
  -- token + pasangan outlet/meja, request serentak untuk meja yang sama jadi
  -- berurutan sebelum fungsi lama menjalankan pemeriksaan anti-spam 15 detik.
  SELECT t.id
    INTO v_table_id
  FROM public.restaurant_tables t
  JOIN public.outlets o ON o.id = t.outlet_id
  WHERE t.id = p_table_id
    AND t.outlet_id = p_outlet_id
    AND t.qr_token = p_table_token
    AND t.is_active
    AND o.is_active
  FOR UPDATE OF t;

  IF v_table_id IS NULL THEN
    RAISE EXCEPTION 'QR meja tidak valid atau sudah tidak aktif'
      USING ERRCODE = '42501';
  END IF;

  RETURN public.create_self_order(
    p_outlet_id     => p_outlet_id,
    p_table_id      => p_table_id,
    p_items         => p_items,
    p_customer_name => p_customer_name,
    p_notes         => p_notes,
    p_promo_code    => p_promo_code,
    p_member_id     => p_member_id,
    p_redeem_points => p_redeem_points
  );
END;
$$;

-- Kontrak lama sengaja tetap ada sebagai implementasi internal agar migration
-- ini kecil dan mudah diaudit, tetapi tidak lagi dapat dipanggil dari API.
REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER
) TO anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT, UUID, INTEGER
) IS
  'Self-order publik yang mewajibkan qr_token valid untuk pasangan meja/outlet. '
  'Meja dikunci selama transaksi agar pembatasan anti-spam bebas race (148).';


CREATE OR REPLACE FUNCTION public.guard_order_shift_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role       TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_shift      public.shifts%ROWTYPE;
BEGIN
  -- SQL administratif/service-role tanpa JWT tetap dapat melakukan maintenance.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.shift_id IS NULL THEN
    IF TG_OP = 'UPDATE' AND OLD.shift_id IS NOT NULL THEN
      RAISE EXCEPTION 'Till order tidak boleh dikosongkan'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang memakai till'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = NEW.shift_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Till tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  -- Offline POS boleh tersinkron setelah kasir clock-out: created_at adalah
  -- waktu transaksi asli dan harus berada di dalam sesi yang ditutup. Order
  -- online baru tetap ditolak bila mencoba memakai till yang sudah tutup.
  IF v_shift.end_time IS NOT NULL
     AND NOT (TG_OP = 'INSERT' AND NEW.created_at <= v_shift.end_time) THEN
    RAISE EXCEPTION 'Till sudah ditutup'
      USING ERRCODE = '22023';
  END IF;
  IF v_role IN ('manajer', 'kasir') AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya boleh memakai till miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_order_shift_assignment() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_guard_order_shift_assignment ON public.orders;
CREATE TRIGGER trg_guard_order_shift_assignment
  BEFORE INSERT OR UPDATE OF shift_id, outlet_id ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_order_shift_assignment();


CREATE OR REPLACE FUNCTION public.guard_payment_shift()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role  TEXT := COALESCE(public.auth_role()::TEXT, '');
  v_order public.orders%ROWTYPE;
  v_shift public.shifts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = NEW.order_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_order.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
    RAISE EXCEPTION 'Pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;

  -- Pembayaran non-tunai tidak memengaruhi saldo laci, tetapi pasangan
  -- order/outlet di atas tetap wajib benar.
  IF NEW.method::TEXT <> 'cash' THEN
    RETURN NEW;
  END IF;

  IF v_role NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Peran tidak berwenang menerima pembayaran tunai'
      USING ERRCODE = '42501';
  END IF;
  IF v_order.shift_id IS NULL THEN
    RAISE EXCEPTION 'Pembayaran tunai wajib memakai till terbuka'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = v_order.shift_id
  FOR KEY SHARE;

  IF NOT FOUND OR v_shift.outlet_id IS DISTINCT FROM v_order.outlet_id THEN
    RAISE EXCEPTION 'Till pembayaran tidak berasal dari outlet order'
      USING ERRCODE = '42501';
  END IF;
  -- Sama seperti order offline, pembayaran offline yang tiba terlambat boleh
  -- dicatat ke sesi historis hanya bila paid_at memang terjadi sebelum till
  -- ditutup. Pembayaran real-time ke till tutup tetap ditolak.
  IF v_shift.end_time IS NOT NULL AND NEW.paid_at > v_shift.end_time THEN
    RAISE EXCEPTION 'Till pembayaran sudah ditutup'
      USING ERRCODE = '22023';
  END IF;
  IF v_role IN ('manajer', 'kasir') AND v_shift.kasir_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Kasir hanya boleh menerima tunai pada till miliknya sendiri'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_payment_shift() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_guard_payment_shift ON public.payments;
CREATE TRIGGER trg_guard_payment_shift
  BEFORE INSERT OR UPDATE OF order_id, outlet_id, method ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.guard_payment_shift();

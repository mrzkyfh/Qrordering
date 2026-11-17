-- 145_fix_transaction_timestamp_trigger.sql
-- Perbaiki migration 143:
-- guard_future_transaction_timestamp() adalah satu fungsi trigger generik yang
-- dipasang pada orders dan payments. Pada sebagian eksekusi PostgreSQL, cabang
-- kondisi tetap memaksa resolusi NEW.paid_at saat NEW adalah baris orders,
-- sehingga insert order gagal dengan:
--   record "new" has no field "paid_at"
--
-- Gunakan satu fungsi untuk setiap tabel agar tipe record NEW selalu cocok.

CREATE OR REPLACE FUNCTION public.guard_order_future_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.created_at > now() + INTERVAL '5 minutes' THEN
    RAISE EXCEPTION 'Waktu order tidak boleh lebih dari 5 menit di masa depan'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_payment_future_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.paid_at > now() + INTERVAL '5 minutes' THEN
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
  EXECUTE FUNCTION public.guard_order_future_timestamp();

DROP TRIGGER IF EXISTS trg_guard_payment_future_timestamp ON public.payments;
CREATE TRIGGER trg_guard_payment_future_timestamp
  BEFORE INSERT ON public.payments
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_payment_future_timestamp();

COMMENT ON FUNCTION public.guard_order_future_timestamp() IS
  'Mencegah order bertimestamp lebih dari 5 menit di masa depan (145).';

COMMENT ON FUNCTION public.guard_payment_future_timestamp() IS
  'Mencegah pembayaran bertimestamp lebih dari 5 menit di masa depan (145).';

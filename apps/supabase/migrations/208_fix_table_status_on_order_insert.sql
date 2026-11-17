-- 208_fix_table_status_on_order_insert.sql
--
-- Order POS dapat langsung dibuat sebagai `confirmed`. Trigger dari migration
-- 089 hanya berjalan saat UPDATE sehingga INSERT tersebut tidak selalu
-- menandai meja sebagai occupied. Perbaikan ini sengaja HANYA mengubah kolom
-- restaurant_tables.status; qr_token/qr_code_url dan identitas meja tidak
-- disentuh sehingga link QR yang sudah dibagikan tetap stabil.

CREATE OR REPLACE FUNCTION public.sync_table_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Pindah meja: bebaskan meja lama bila tidak dipakai order aktif lain.
  IF TG_OP = 'UPDATE' THEN
    IF OLD.table_id IS DISTINCT FROM NEW.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
         FROM public.orders o
         WHERE o.table_id = OLD.table_id
           AND o.id <> NEW.id
           AND o.status IN ('confirmed', 'preparing', 'ready', 'served')
       ) THEN
      UPDATE public.restaurant_tables
      SET status = 'available'
      WHERE id = OLD.table_id;
    END IF;
  END IF;

  -- INSERT order confirmed maupun perkembangan status order menempati meja.
  IF NEW.table_id IS NOT NULL
     AND NEW.status IN ('confirmed', 'preparing', 'ready', 'served') THEN
    UPDATE public.restaurant_tables
    SET status = 'occupied'
    WHERE id = NEW.table_id;
  END IF;

  -- Meja baru boleh bebas setelah tidak ada order aktif lain di meja itu.
  IF NEW.table_id IS NOT NULL
     AND NEW.status IN ('paid', 'cancelled', 'void')
     AND NOT EXISTS (
       SELECT 1
       FROM public.orders o
       WHERE o.table_id = NEW.table_id
         AND o.id <> NEW.id
         AND o.status IN ('confirmed', 'preparing', 'ready', 'served')
     ) THEN
    UPDATE public.restaurant_tables
    SET status = 'available'
    WHERE id = NEW.table_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Pisahkan event INSERT dan UPDATE agar daftar kolom UPDATE tetap eksplisit.
DROP TRIGGER IF EXISTS trg_sync_table_status_insert ON public.orders;
CREATE TRIGGER trg_sync_table_status_insert
  AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_table_status();

DROP TRIGGER IF EXISTS trg_sync_table_status ON public.orders;
CREATE TRIGGER trg_sync_table_status
  AFTER UPDATE OF status, table_id ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_table_status();

-- Pulihkan data lama yang telanjur tidak sinkron. UPDATE ini hanya menyentuh
-- `status`; token dan URL QR tidak berubah.
UPDATE public.restaurant_tables t
SET status = CASE
  WHEN EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.table_id = t.id
      AND o.status IN ('confirmed', 'preparing', 'ready', 'served')
  ) THEN 'occupied'::public.table_status
  ELSE 'available'::public.table_status
END
WHERE t.status IN ('available', 'occupied')
  AND t.status IS DISTINCT FROM CASE
  WHEN EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.table_id = t.id
      AND o.status IN ('confirmed', 'preparing', 'ready', 'served')
  ) THEN 'occupied'::public.table_status
  ELSE 'available'::public.table_status
END;

COMMENT ON FUNCTION public.sync_table_status() IS
  'Sinkronkan occupied/available dari order aktif tanpa mengubah token atau URL QR meja.';

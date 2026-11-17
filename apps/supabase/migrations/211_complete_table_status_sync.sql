-- 211_complete_table_status_sync.sql
--
-- Penyempurnaan migration 208:
--   * order `draft` (termasuk self-order QR) langsung menempati meja;
--   * DELETE order aktif juga menyegarkan status meja;
--   * rekonsiliasi tidak lagi merusak status manual `reserved` / `dirty`;
--   * hanya kolom status yang disentuh. qr_token dan qr_code_url tetap stabil.

CREATE OR REPLACE FUNCTION public.sync_table_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- DELETE tidak memiliki NEW. Setelah row hilang, bebaskan meja hanya bila
  -- tidak ada order aktif lain dan status saat ini memang `occupied`.
  IF TG_OP = 'DELETE' THEN
    IF OLD.table_id IS NOT NULL
       AND OLD.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
       AND NOT EXISTS (
         SELECT 1
         FROM public.orders o
         WHERE o.table_id = OLD.table_id
           AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
       ) THEN
      UPDATE public.restaurant_tables
      SET status = 'available'
      WHERE id = OLD.table_id
        AND status = 'occupied';
    END IF;
    RETURN OLD;
  END IF;

  -- Pindah meja: meja lama bebas bila tidak dipakai order aktif lain. Guard
  -- status menjaga reserved/dirty yang diatur manual tidak tertimpa.
  IF TG_OP = 'UPDATE'
     AND OLD.table_id IS DISTINCT FROM NEW.table_id
     AND OLD.table_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM public.orders o
       WHERE o.table_id = OLD.table_id
         AND o.id <> NEW.id
         AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
     ) THEN
    UPDATE public.restaurant_tables
    SET status = 'available'
    WHERE id = OLD.table_id
      AND status = 'occupied';
  END IF;

  -- Draf adalah open bill yang nyata. Ini juga membuat self-order QR langsung
  -- menandai meja terisi sebelum kasir mengonfirmasi pesanan.
  IF NEW.table_id IS NOT NULL
     AND NEW.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served') THEN
    UPDATE public.restaurant_tables
    SET status = 'occupied'
    WHERE id = NEW.table_id;
  END IF;

  -- Status terminal membebaskan meja setelah order aktif terakhir selesai.
  IF NEW.table_id IS NOT NULL
     AND NEW.status IN ('paid', 'cancelled', 'void')
     AND NOT EXISTS (
       SELECT 1
       FROM public.orders o
       WHERE o.table_id = NEW.table_id
         AND o.id <> NEW.id
         AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
     ) THEN
    UPDATE public.restaurant_tables
    SET status = 'available'
    WHERE id = NEW.table_id
      AND status = 'occupied';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_table_status_insert ON public.orders;
CREATE TRIGGER trg_sync_table_status_insert
  AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_table_status();

DROP TRIGGER IF EXISTS trg_sync_table_status ON public.orders;
CREATE TRIGGER trg_sync_table_status
  AFTER UPDATE OF status, table_id ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_table_status();

DROP TRIGGER IF EXISTS trg_sync_table_status_delete ON public.orders;
CREATE TRIGGER trg_sync_table_status_delete
  AFTER DELETE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_table_status();

-- Rekonsiliasi hanya mengubah available/occupied. Status reserved/dirty tanpa
-- order aktif tidak boleh hilang akibat deployment migration.
UPDATE public.restaurant_tables t
SET status = 'occupied'
WHERE t.status IS DISTINCT FROM 'occupied'::public.table_status
  AND EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.table_id = t.id
      AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
  );

UPDATE public.restaurant_tables t
SET status = 'available'
WHERE t.status = 'occupied'
  AND NOT EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.table_id = t.id
      AND o.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')
  );

COMMENT ON FUNCTION public.sync_table_status() IS
  'Sinkronkan meja untuk seluruh open bill termasuk draft/QR dan DELETE tanpa mengubah link QR.';

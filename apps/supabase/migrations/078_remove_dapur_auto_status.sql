-- ============================================================
-- 078_remove_dapur_auto_status.sql — Fase 1 hapus dapur + status otomatis
--   1. Longgarkan transisi status: order boleh langsung LUNAS tanpa antrian
--      dapur (draft/confirmed/preparing/ready/served → paid).
--   2. Konversi akun role 'dapur' lama → 'kasir' (dapur ditiadakan).
--
-- CATATAN: nilai enum user_role 'dapur' DIBIARKAN (Postgres tak bisa drop value
-- enum dengan mudah). Cukup tidak dipakai lagi & disembunyikan dari UI.
-- ============================================================

-- ── 1. State machine baru: izinkan langsung ke 'paid' ─────────────────────────
CREATE OR REPLACE FUNCTION validate_order_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  valid_next TEXT[];
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  CASE OLD.status
    -- Tanpa dapur: order terbuka boleh langsung lunas. Tahap masak (preparing/
    -- ready/served) tetap diizinkan untuk kompatibilitas data lama.
    WHEN 'draft'     THEN valid_next := ARRAY['confirmed','paid','cancelled','void'];
    WHEN 'confirmed' THEN valid_next := ARRAY['preparing','ready','served','paid','cancelled','void'];
    WHEN 'preparing' THEN valid_next := ARRAY['ready','served','paid','cancelled','void'];
    WHEN 'ready'     THEN valid_next := ARRAY['served','paid','cancelled','void'];
    WHEN 'served'    THEN valid_next := ARRAY['paid','void'];
    ELSE valid_next := ARRAY[]::TEXT[];
  END CASE;

  IF NOT (NEW.status::TEXT = ANY(valid_next)) THEN
    RAISE EXCEPTION 'invalid order status transition: % → %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

-- ── 2. Konversi staf dapur lama → kasir ───────────────────────────────────────
UPDATE profiles SET role = 'kasir', updated_at = NOW() WHERE role = 'dapur';

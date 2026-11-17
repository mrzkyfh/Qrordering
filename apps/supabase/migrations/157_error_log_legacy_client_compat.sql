-- 157_error_log_legacy_client_compat.sql
-- Kompatibilitas aplikasi yang sudah terpasang dan masih INSERT langsung.
-- Versi baru memakai record_error_log(); versi lama dinormalisasi trigger.

CREATE OR REPLACE FUNCTION public.normalize_legacy_error_log_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_existing UUID;
  v_outlet UUID;
BEGIN
  -- RPC baru sudah mengirim fingerprint dan menangani upsert sendiri.
  IF NEW.fingerprint IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan';
  END IF;

  NEW.user_id := auth.uid();
  v_outlet := CASE
    WHEN public.auth_role() = 'owner' THEN NEW.outlet_id
    ELSE public.auth_outlet_id()
  END;
  NEW.outlet_id := v_outlet;
  NEW.message := LEFT(COALESCE(NULLIF(btrim(NEW.message), ''), 'Error tanpa pesan'), 1000);
  NEW.stack := CASE WHEN NEW.stack IS NULL THEN NULL ELSE LEFT(NEW.stack, 4000) END;
  NEW.platform := LEFT(NEW.platform, 50);
  NEW.fingerprint := md5(
    lower(regexp_replace(NEW.message, '[0-9a-f]{8}-[0-9a-f-]{27,}', '<uuid>', 'gi'))
    || E'\n' || COALESCE(split_part(NEW.stack, E'\n', 1), '')
    || E'\n' || COALESCE(NEW.app_build::TEXT, '')
    || E'\n' || COALESCE(NEW.platform, '')
    || E'\n' || COALESCE(v_outlet::TEXT, '')
  );
  NEW.occurrence_count := 1;
  NEW.first_seen_at := COALESCE(NEW.first_seen_at, now());
  NEW.last_seen_at := now();
  NEW.created_at := now();

  SELECT id INTO v_existing
  FROM public.error_logs
  WHERE fingerprint = NEW.fingerprint
  FOR UPDATE;

  IF v_existing IS NOT NULL THEN
    UPDATE public.error_logs
    SET
      message = NEW.message,
      stack = NEW.stack,
      user_id = NEW.user_id,
      occurrence_count = occurrence_count + 1,
      last_seen_at = now(),
      created_at = now()
    WHERE id = v_existing;
    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_legacy_error_log_insert ON public.error_logs;
CREATE TRIGGER trg_normalize_legacy_error_log_insert
  BEFORE INSERT ON public.error_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_legacy_error_log_insert();

DROP POLICY IF EXISTS "error_logs_insert" ON public.error_logs;
CREATE POLICY "error_logs_insert" ON public.error_logs
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

GRANT INSERT ON public.error_logs TO authenticated;
REVOKE ALL ON FUNCTION public.normalize_legacy_error_log_insert()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.normalize_legacy_error_log_insert() IS
  'Menjaga aplikasi versi lama tetap bisa mengirim log tanpa memenuhi database.';

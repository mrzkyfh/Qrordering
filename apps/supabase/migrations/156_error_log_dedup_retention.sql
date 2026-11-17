-- 156_error_log_dedup_retention.sql
-- Error operasional: gabungkan kejadian yang sama, potong payload, simpan tujuh
-- hari, dan batasi maksimal 5.000 fingerprint terbaru.

ALTER TABLE public.error_logs
  ADD COLUMN IF NOT EXISTS fingerprint TEXT,
  ADD COLUMN IF NOT EXISTS occurrence_count INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS first_seen_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;

UPDATE public.error_logs
SET
  message = LEFT(message, 1000),
  stack = CASE WHEN stack IS NULL THEN NULL ELSE LEFT(stack, 4000) END,
  fingerprint = COALESCE(
    fingerprint,
    md5(
      lower(regexp_replace(message, '[0-9a-f]{8}-[0-9a-f-]{27,}', '<uuid>', 'gi'))
      || E'\n' || COALESCE(split_part(stack, E'\n', 1), '')
      || E'\n' || COALESCE(app_build::TEXT, '')
      || E'\n' || COALESCE(platform, '')
      || E'\n' || COALESCE(outlet_id::TEXT, '')
    )
  ),
  first_seen_at = COALESCE(first_seen_at, created_at),
  last_seen_at = COALESCE(last_seen_at, created_at)
WHERE fingerprint IS NULL OR first_seen_at IS NULL OR last_seen_at IS NULL
  OR length(message) > 1000 OR length(COALESCE(stack, '')) > 4000;

-- Pertahankan satu baris terbaru per fingerprint sebelum unique index dibuat.
WITH ranked AS (
  SELECT id,
    ROW_NUMBER() OVER (
      PARTITION BY fingerprint
      ORDER BY COALESCE(last_seen_at, created_at) DESC, id DESC
    ) AS rn
  FROM public.error_logs
)
DELETE FROM public.error_logs e
USING ranked r
WHERE e.id = r.id AND r.rn > 1;

ALTER TABLE public.error_logs
  ALTER COLUMN fingerprint SET NOT NULL,
  ALTER COLUMN first_seen_at SET DEFAULT now(),
  ALTER COLUMN first_seen_at SET NOT NULL,
  ALTER COLUMN last_seen_at SET DEFAULT now(),
  ALTER COLUMN last_seen_at SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_error_logs_fingerprint
  ON public.error_logs(fingerprint);
CREATE INDEX IF NOT EXISTS idx_error_logs_last_seen
  ON public.error_logs(last_seen_at DESC);

CREATE OR REPLACE FUNCTION public.record_error_log(
  p_message TEXT,
  p_stack TEXT DEFAULT NULL,
  p_app_build INTEGER DEFAULT NULL,
  p_platform TEXT DEFAULT NULL,
  p_outlet_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_role public.user_role := public.auth_role();
  v_user_outlet UUID := public.auth_outlet_id();
  v_message TEXT := LEFT(COALESCE(NULLIF(btrim(p_message), ''), 'Error tanpa pesan'), 1000);
  v_stack TEXT := CASE WHEN p_stack IS NULL THEN NULL ELSE LEFT(p_stack, 4000) END;
  v_outlet UUID;
  v_fingerprint TEXT;
  v_id UUID;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan';
  END IF;

  v_outlet := CASE
    WHEN v_role = 'owner' THEN p_outlet_id
    ELSE v_user_outlet
  END;
  v_fingerprint := md5(
    lower(regexp_replace(v_message, '[0-9a-f]{8}-[0-9a-f-]{27,}', '<uuid>', 'gi'))
    || E'\n' || COALESCE(split_part(v_stack, E'\n', 1), '')
    || E'\n' || COALESCE(p_app_build::TEXT, '')
    || E'\n' || COALESCE(LEFT(p_platform, 50), '')
    || E'\n' || COALESCE(v_outlet::TEXT, '')
  );

  INSERT INTO public.error_logs (
    message, stack, app_build, platform, user_id, outlet_id,
    fingerprint, occurrence_count, first_seen_at, last_seen_at, created_at
  )
  VALUES (
    v_message, v_stack, p_app_build, LEFT(p_platform, 50), v_user, v_outlet,
    v_fingerprint, 1, now(), now(), now()
  )
  ON CONFLICT (fingerprint) DO UPDATE SET
    message = EXCLUDED.message,
    stack = EXCLUDED.stack,
    user_id = EXCLUDED.user_id,
    occurrence_count = public.error_logs.occurrence_count + 1,
    last_seen_at = now(),
    created_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_error_log(TEXT, TEXT, INTEGER, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_error_log(TEXT, TEXT, INTEGER, TEXT, UUID)
  TO authenticated;

-- Direct INSERT tidak lagi diperlukan; semua input melewati validasi RPC.
DROP POLICY IF EXISTS "error_logs_insert" ON public.error_logs;
REVOKE INSERT ON public.error_logs FROM authenticated;

CREATE OR REPLACE FUNCTION public.prune_error_logs(
  p_keep_days INTEGER DEFAULT 7,
  p_max_rows INTEGER DEFAULT 5000
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_deleted INTEGER := 0;
  v_batch INTEGER;
BEGIN
  LOOP
    WITH doomed AS (
      SELECT id
      FROM public.error_logs
      WHERE last_seen_at < now() - make_interval(days => GREATEST(p_keep_days, 1))
      ORDER BY last_seen_at
      LIMIT 1000
    )
    DELETE FROM public.error_logs e USING doomed d WHERE e.id = d.id;
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_deleted := v_deleted + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;

  WITH excess AS (
    SELECT id
    FROM public.error_logs
    ORDER BY last_seen_at DESC, id DESC
    OFFSET GREATEST(p_max_rows, 100)
  )
  DELETE FROM public.error_logs e USING excess x WHERE e.id = x.id;
  GET DIAGNOSTICS v_batch = ROW_COUNT;
  RETURN v_deleted + v_batch;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_error_logs(INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;

SELECT cron.schedule(
  'prune-error-logs',
  '20 19 * * *',
  $$SELECT public.prune_error_logs(7, 5000);$$
);

COMMENT ON FUNCTION public.record_error_log(TEXT, TEXT, INTEGER, TEXT, UUID) IS
  'Mencatat error terautentikasi, memotong payload, dan menggabungkan fingerprint yang sama.';

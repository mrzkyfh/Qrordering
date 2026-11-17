-- 159_archive_manual_trigger.sql
-- Pemicu manual yang aman untuk verifikasi operasional. Secret tetap dibaca
-- dari Vault dan fungsi hanya dapat dipanggil oleh service_role.

CREATE OR REPLACE FUNCTION public.request_transaction_archive_run(
  p_keep_days INTEGER DEFAULT 90,
  p_limit_days INTEGER DEFAULT 5,
  p_invoked_by TEXT DEFAULT 'manual'
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_secret TEXT;
  v_request_id BIGINT;
BEGIN
  SELECT decrypted_secret
  INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'transaction_archive_job_secret'
  LIMIT 1;

  IF NULLIF(v_secret, '') IS NULL THEN
    RAISE EXCEPTION 'Secret pekerjaan arsip belum tersedia di Vault';
  END IF;

  SELECT net.http_post(
    url := 'https://jstdtalbihxlbpfsisab.supabase.co/functions/v1/archive-orders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-archive-secret', v_secret
    ),
    body := jsonb_build_object(
      'keep_days', GREATEST(COALESCE(p_keep_days, 90), 90),
      'limit_days', GREATEST(1, LEAST(COALESCE(p_limit_days, 5), 10)),
      'invoked_by',
        CASE WHEN p_invoked_by IN ('manual', 'test') THEN p_invoked_by ELSE 'manual' END
    ),
    timeout_milliseconds := 50000
  )
  INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_transaction_archive_run(
  INTEGER, INTEGER, TEXT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_transaction_archive_run(
  INTEGER, INTEGER, TEXT
) TO service_role;

COMMENT ON FUNCTION public.request_transaction_archive_run(INTEGER, INTEGER, TEXT)
IS 'Memicu Edge Function arsip memakai secret Vault; khusus service_role untuk operasi dan pengujian.';

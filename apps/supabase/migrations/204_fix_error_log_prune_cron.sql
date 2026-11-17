-- Pastikan hanya ada satu signature prune_error_logs dan cron memakai retensi
-- tujuh hari secara eksplisit. Signature satu argumen dari migrasi lama membuat
-- pemanggilan cron ambigu setelah signature dua argumen ditambahkan.

DROP FUNCTION IF EXISTS public.prune_error_logs(INTEGER);

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'prune-error-logs';

SELECT cron.schedule(
  'prune-error-logs',
  '20 19 * * *',
  $$SELECT public.prune_error_logs(7, 5000);$$
);

-- Bersihkan backlog sekarang; eksekusi berikutnya berjalan setiap 02:20 WIB.
SELECT public.prune_error_logs(7, 5000);

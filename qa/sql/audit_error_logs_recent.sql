SELECT
  app_build,
  platform,
  occurrence_count,
  last_seen_at,
  LEFT(message, 180) AS message
FROM public.error_logs
WHERE last_seen_at >= now() - interval '7 days'
ORDER BY last_seen_at DESC;

SELECT
  COUNT(*) AS fingerprints_last_7_days,
  COALESCE(SUM(occurrence_count), 0) AS occurrences_last_7_days,
  COUNT(*) FILTER (WHERE app_build >= 48) AS current_build_fingerprints
FROM public.error_logs
WHERE last_seen_at >= now() - interval '7 days';

SELECT app_build, platform, COUNT(*) AS fingerprints,
       COALESCE(SUM(occurrence_count), 0) AS occurrences
FROM public.error_logs
WHERE last_seen_at >= now() - interval '7 days'
GROUP BY app_build, platform
ORDER BY app_build DESC NULLS LAST;

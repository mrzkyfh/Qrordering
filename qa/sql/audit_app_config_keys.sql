SELECT key, left(value, 80) AS value_preview
FROM public.app_config
ORDER BY key;

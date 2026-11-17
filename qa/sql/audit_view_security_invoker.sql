SELECT c.relname AS view_name,
       COALESCE(array_to_string(c.reloptions, ', '), '') AS reloptions
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'v'
  AND (c.reloptions IS NULL OR NOT ('security_invoker=on' = ANY(c.reloptions)))
ORDER BY c.relname;

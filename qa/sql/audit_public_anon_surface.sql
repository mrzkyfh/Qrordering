SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('app_config', 'profiles', 'error_logs', 'transaction_archive_runs')
ORDER BY table_name, ordinal_position;

SELECT schemaname, tablename, policyname, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('app_config', 'profiles', 'error_logs', 'transaction_archive_runs')
ORDER BY tablename, policyname;

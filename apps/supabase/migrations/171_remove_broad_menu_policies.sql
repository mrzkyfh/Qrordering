-- ============================================================
-- 171_remove_broad_menu_policies.sql
--
-- Migration 063 accidentally left broad policies active after the tenant
-- scoped policies from migration 048 were installed. PostgreSQL combines
-- permissive policies with OR, so the old policies allowed an admin from one
-- outlet to write menu extras belonging to another outlet and allowed public
-- reads that bypassed the scoped policy set.
--
-- The customer menu uses get_public_menu_snapshot() (migration 169), while
-- the legacy compatibility path is still limited to active menu rows by the
-- policies from migrations 038/048. Remove only the broad 063 policies and
-- leave those scoped policies intact.
-- ============================================================

DO $$
DECLARE
  item record;
BEGIN
  FOR item IN
    SELECT * FROM (VALUES
      ('menu_departments'::text, 'dept_access_read'::text),
      ('menu_departments',       'dept_access_write'),
      ('menu_extras',            'extras_access_read'),
      ('menu_extras',            'extras_access_write'),
      ('menu_extra_options',     'extra_options_access_read'),
      ('menu_extra_options',     'extra_options_access_write'),
      ('menu_item_extras',       'item_extras_access_read'),
      ('menu_item_extras',       'item_extras_access_write')
    ) AS policies(table_name, policy_name)
  LOOP
    IF to_regclass(format('public.%I', item.table_name)) IS NOT NULL THEN
      EXECUTE format(
        'DROP POLICY IF EXISTS %I ON public.%I',
        item.policy_name,
        item.table_name
      );
    END IF;
  END LOOP;
END
$$;

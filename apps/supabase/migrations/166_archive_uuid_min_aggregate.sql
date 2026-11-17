-- 166_archive_uuid_min_aggregate.sql
--
-- finalize_transaction_archive mengelompokkan opsi tambahan dan memilih satu
-- menu_extra_id representatif dengan MIN(uuid). PostgreSQL tidak menyediakan
-- overload MIN untuk UUID, sehingga fungsi arsip lolos CREATE FUNCTION tetapi
-- gagal saat dijalankan. Sediakan aggregate UUID yang dibutuhkan fungsi itu.

CREATE OR REPLACE FUNCTION public.uuid_min(UUID, UUID)
RETURNS UUID
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS 'SELECT CASE WHEN $1 < $2 THEN $1 ELSE $2 END';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'min'
      AND p.prokind = 'a'
      AND p.proargtypes = '2950'::OIDVECTOR
  ) THEN
    CREATE AGGREGATE public.min(UUID) (
      SFUNC = public.uuid_min,
      STYPE = UUID,
      SORTOP = OPERATOR(pg_catalog.<)
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.uuid_min(UUID, UUID) FROM PUBLIC;

COMMENT ON AGGREGATE public.min(UUID) IS
  'MIN untuk UUID; dipakai finalisasi arsip transaksi saat mengelompokkan '
  'menu_extra_id.';

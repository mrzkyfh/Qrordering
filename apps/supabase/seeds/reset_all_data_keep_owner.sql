-- ============================================================================
-- reset_all_data_keep_owner.sql
-- FACTORY RESET data POS, tetapi mempertahankan satu akun Auth owner.
--
-- Cocok dijalankan tepat sebelum aplikasi benar-benar mulai digunakan setelah
-- periode setup, demo, atau QA selesai.
--
-- YANG DIHAPUS
--   - seluruh transaksi, pembayaran, refund, shift, kas, dan arsip transaksi;
--   - seluruh outlet dan master data (menu, stok, promo, meja, supplier, dll.);
--   - seluruh staf, akun perangkat, dan user Auth selain owner yang dipilih;
--   - PIN owner, konfigurasi outlet, log error, serta data monitoring.
--
-- YANG DIPERTAHANKAN
--   - email, password, identity, dan akun Auth owner yang dipilih;
--   - nama owner (profile dibuat ulang dengan role = owner dan is_active = true);
--   - konfigurasi global app_config (contoh: minimum build aplikasi);
--   - struktur database, migration, function, trigger, RLS, Supabase Storage
--     bucket, dan Cloudflare R2 bucket (hanya isinya yang harus dikosongkan).
--
-- PENTING
--   1. Backup database lebih dulu.
--   2. SEBELUM menjalankan SQL ini, kosongkan semua bucket lewat Supabase
--      Storage Dashboard/API. Auth user yang masih memiliki file tidak dapat
--      dihapus. Jangan menghapus storage.objects langsung melalui SQL.
--   3. Kosongkan juga Cloudflare R2 bucket `time420s-images` melalui Dashboard.
--      SQL Supabase tidak dapat memeriksa atau menghapus object di Cloudflare.
--   4. Jalankan script ini hanya melalui Supabase Dashboard -> SQL Editor.
--   5. Edit TIGA nilai pada blok _pos_reset_config di bawah. Konfirmasi R2
--      merupakan pernyataan operator karena tidak dapat diverifikasi oleh SQL.
--   6. Jangan jalankan migration lagi setelah script ini. app_config yang aktif
--      sengaja dipertahankan agar gate minimum build tidak berubah.
--
-- Supabase Storage bucket saat script dibuat: menu-images, qr-codes, dan
-- transaction-archives. Guard di bawah memeriksa SELURUH storage.objects agar
-- bucket baru juga tidak terlewat. Cloudflare R2 diperiksa secara operasional
-- melalui konfirmasi terpisah karena berada di luar database Supabase.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- KONFIGURASI: WAJIB EDIT DUA NILAI INI
-- --------------------------------------------------------------------------
CREATE TEMP TABLE _pos_reset_config (
  owner_email     TEXT NOT NULL,
  confirmation    TEXT NOT NULL,
  r2_confirmation TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO _pos_reset_config (owner_email, confirmation, r2_confirmation)
VALUES (
  'GANTI_DENGAN_EMAIL_OWNER',
  'KETIK: HAPUS SEMUA DATA POS',
  'KETIK: R2 TIME420S-IMAGES SUDAH KOSONG'
);

-- Guard pertama: mencegah eksekusi tanpa konfirmasi eksplisit.
DO $$
DECLARE
  v_confirmation TEXT;
  v_r2_confirmation TEXT;
BEGIN
  SELECT confirmation, r2_confirmation
  INTO v_confirmation, v_r2_confirmation
  FROM _pos_reset_config;

  IF v_confirmation <> 'HAPUS SEMUA DATA POS' THEN
    RAISE EXCEPTION
      'RESET DIBATALKAN: ubah confirmation menjadi persis "HAPUS SEMUA DATA POS".';
  END IF;

  IF v_r2_confirmation <> 'R2 TIME420S-IMAGES SUDAH KOSONG' THEN
    RAISE EXCEPTION
      'RESET DIBATALKAN: kosongkan Cloudflare R2 bucket time420s-images, lalu ubah r2_confirmation menjadi persis "R2 TIME420S-IMAGES SUDAH KOSONG".';
  END IF;
END
$$;

-- Simpan owner sebelum seluruh tabel public dikosongkan. Owner harus sudah
-- memiliki profile dengan role owner. Script berhenti bila email salah atau
-- akun tersebut belum dipromosikan menjadi owner.
CREATE TEMP TABLE _pos_reset_owner (
  id        UUID PRIMARY KEY,
  full_name TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO _pos_reset_owner (id, full_name)
SELECT
  u.id,
  COALESCE(NULLIF(BTRIM(p.full_name), ''), split_part(u.email, '@', 1))
FROM auth.users AS u
JOIN public.profiles AS p ON p.id = u.id
CROSS JOIN _pos_reset_config AS c
WHERE LOWER(u.email) = LOWER(BTRIM(c.owner_email))
  AND p.role::TEXT = 'owner';

DO $$
DECLARE
  v_owner_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_owner_count FROM _pos_reset_owner;

  IF v_owner_count <> 1 THEN
    RAISE EXCEPTION
      'RESET DIBATALKAN: email harus cocok dengan tepat satu akun yang profile.role = owner.';
  END IF;
END
$$;

-- Supabase melarang penghapusan Auth user yang masih memiliki Storage object.
-- Metadata boleh dibaca dari SQL, tetapi file wajib dihapus melalui API/Dashboard
-- agar binary di storage provider ikut terhapus dan tidak menjadi orphan.
-- Guard ini tidak mencakup Cloudflare R2; konfirmasi operator di atas wajib
-- diberikan hanya setelah bucket time420s-images benar-benar kosong.
DO $$
DECLARE
  v_storage_count BIGINT;
  v_storage_detail TEXT;
BEGIN
  SELECT
    COALESCE(SUM(x.object_count), 0),
    string_agg(format('%s (%s file)', x.bucket_id, x.object_count), ', ' ORDER BY x.bucket_id)
  INTO v_storage_count, v_storage_detail
  FROM (
    SELECT bucket_id, COUNT(*) AS object_count
    FROM storage.objects
    GROUP BY bucket_id
  ) AS x;

  IF v_storage_count > 0 THEN
    RAISE EXCEPTION
      'RESET DIBATALKAN: Storage masih berisi % file: %. Kosongkan bucket lewat Storage Dashboard/API, lalu jalankan ulang.',
      v_storage_count, v_storage_detail;
  END IF;
END
$$;

-- Daftar lengkap tabel aplikasi yang sudah ditinjau saat script dibuat.
-- Guard setelah blok ini akan berhenti jika migration baru menambah tabel public,
-- sehingga tabel baru tidak tertinggal atau terhapus tanpa sengaja.
CREATE TEMP TABLE _pos_reset_known_tables (
  name TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO _pos_reset_known_tables (name) VALUES
  ('app_config'),
  ('archived_cashier_sales_daily'),
  ('archived_extra_sales_daily'),
  ('archived_item_sales_daily'),
  ('archived_payment_sales_daily'),
  ('archived_peak_hours_daily'),
  ('archived_refund_sales_daily'),
  ('attendances'),
  ('bundle_items'),
  ('cash_movements'),
  ('commission_rules'),
  ('db_size_log'),
  ('error_logs'),
  ('expenses'),
  ('ingredients'),
  ('loyalty_members'),
  ('loyalty_transactions'),
  ('menu_categories'),
  ('menu_departments'),
  ('menu_extra_options'),
  ('menu_extras'),
  ('menu_item_extras'),
  ('menu_items'),
  ('menu_recipes'),
  ('order_audit_log'),
  ('order_daily_counters'),
  ('order_item_append_requests'),
  ('order_item_options'),
  ('order_item_voids'),
  ('order_items'),
  ('orders'),
  ('outlets'),
  ('outlets_public_projection'),
  ('payments'),
  ('profiles'),
  ('promo_usages'),
  ('promos'),
  ('refund_items'),
  ('refunds'),
  ('restaurant_tables'),
  ('sales_daily_summary'),
  ('shifts'),
  ('stock_opname_items'),
  ('stock_opnames'),
  ('stock_transactions'),
  ('suppliers'),
  ('transaction_archive_manifest'),
  ('transaction_archive_orders'),
  ('transaction_archive_runs'),
  ('vouchers');

DO $$
DECLARE
  v_unknown_tables TEXT[];
BEGIN
  SELECT ARRAY_AGG(t.tablename ORDER BY t.tablename)
  INTO v_unknown_tables
  FROM pg_catalog.pg_tables AS t
  WHERE t.schemaname = 'public'
    AND NOT EXISTS (
      SELECT 1
      FROM _pos_reset_known_tables AS k
      WHERE k.name = t.tablename
    );

  IF COALESCE(cardinality(v_unknown_tables), 0) > 0 THEN
    RAISE EXCEPTION
      'RESET DIBATALKAN: ada tabel public yang belum ditinjau: %. Perbarui daftar _pos_reset_known_tables terlebih dahulu.',
      array_to_string(v_unknown_tables, ', ');
  END IF;
END
$$;

-- Kosongkan hanya tabel yang benar-benar ada. app_config adalah konfigurasi
-- sistem global, bukan data operasional, sehingga sengaja dipertahankan.
-- RESTART IDENTITY mengembalikan sequence ke nilai awal; CASCADE menangani FK.
DO $$
DECLARE
  v_target_tables TEXT;
BEGIN
  SELECT string_agg(
           format('%I.%I', t.schemaname, t.tablename),
           ', ' ORDER BY t.tablename
         )
  INTO v_target_tables
  FROM pg_catalog.pg_tables AS t
  JOIN _pos_reset_known_tables AS k ON k.name = t.tablename
  WHERE t.schemaname = 'public'
    AND t.tablename <> 'app_config';

  IF v_target_tables IS NULL THEN
    RAISE EXCEPTION 'RESET DIBATALKAN: tidak ada tabel aplikasi di schema public.';
  END IF;

  EXECUTE 'TRUNCATE TABLE ' || v_target_tables || ' RESTART IDENTITY CASCADE';
END
$$;

-- Hapus seluruh akun Auth selain owner terpilih. Ini termasuk owner lain bila
-- ada; hanya SATU akun yang memang dipertahankan oleh factory reset ini.
DELETE FROM auth.users
WHERE id <> (SELECT id FROM _pos_reset_owner);

-- Buat ulang profile owner dalam keadaan bersih. outlet_id dan PIN sengaja NULL.
INSERT INTO public.profiles (
  id,
  outlet_id,
  role,
  full_name,
  is_active
)
SELECT
  id,
  NULL,
  'owner',
  full_name,
  TRUE
FROM _pos_reset_owner;

-- Verifikasi sebelum COMMIT. Setiap kegagalan membuat seluruh reset rollback.
DO $$
DECLARE
  v_auth_count       INTEGER;
  v_profile_count    INTEGER;
  v_owner_count      INTEGER;
  v_table_name       TEXT;
  v_has_rows         BOOLEAN;
  v_nonempty_tables  TEXT[] := ARRAY[]::TEXT[];
BEGIN
  SELECT COUNT(*) INTO v_auth_count FROM auth.users;
  SELECT COUNT(*) INTO v_profile_count FROM public.profiles;
  SELECT COUNT(*) INTO v_owner_count
  FROM public.profiles
  WHERE role::TEXT = 'owner' AND is_active = TRUE AND outlet_id IS NULL;

  IF v_auth_count <> 1 OR v_profile_count <> 1 OR v_owner_count <> 1 THEN
    RAISE EXCEPTION
      'RESET GAGAL VERIFIKASI: auth_users=%, profiles=%, active_owner_without_outlet=%.',
      v_auth_count, v_profile_count, v_owner_count;
  END IF;

  -- Selain profiles dan app_config yang sengaja dibuat ulang, semua tabel public
  -- harus benar-benar kosong. Pemeriksaan memakai SELECT aktual, bukan statistik.
  FOR v_table_name IN
    SELECT k.name
    FROM _pos_reset_known_tables AS k
    WHERE k.name NOT IN ('profiles', 'app_config')
      AND to_regclass(format('public.%I', k.name)) IS NOT NULL
    ORDER BY k.name
  LOOP
    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM public.%I LIMIT 1)',
      v_table_name
    ) INTO v_has_rows;

    IF v_has_rows THEN
      v_nonempty_tables := array_append(v_nonempty_tables, v_table_name);
    END IF;
  END LOOP;

  IF cardinality(v_nonempty_tables) > 0 THEN
    RAISE EXCEPTION
      'RESET GAGAL VERIFIKASI: tabel berikut masih berisi data: %.',
      array_to_string(v_nonempty_tables, ', ');
  END IF;
END
$$;

COMMIT;

-- Ringkasan hasil. Harus menghasilkan tepat satu akun owner dan nol akun lain.
SELECT
  u.email,
  p.full_name,
  p.role,
  p.outlet_id,
  p.is_active,
  (SELECT COUNT(*) FROM auth.users) AS total_auth_users,
  (SELECT COUNT(*) FROM public.outlets) AS total_outlets,
  (SELECT COUNT(*) FROM public.orders) AS total_orders,
  (SELECT COUNT(*) FROM public.menu_items) AS total_menu_items
FROM auth.users AS u
JOIN public.profiles AS p ON p.id = u.id;

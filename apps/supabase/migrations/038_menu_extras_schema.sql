-- ============================================================
-- 038_menu_extras_schema.sql
-- Tabel master untuk extra/add-on menu + junction ke menu_items
-- (dibutuhkan oleh FK di migration 039_order_item_options.sql)
--
-- CATATAN NOMOR: berkas ini dulu bernomor 039 dan order_item_options bernomor
-- 038 — pemakai FK berjalan SEBELUM pembuat tabelnya. Di produksi hal itu tak
-- terlihat (keduanya sudah terlanjur ada), tapi rantai migration jadi MUSTAHIL
-- dibangun dari DB kosong: 038 lama selalu gagal "relation menu_extras does not
-- exist", sehingga staging/preview/DR tak bisa dibuat dari repo. Nomornya
-- ditukar agar urutan berkas = urutan ketergantungan.
--
-- Aman untuk DB yang sudah jalan: `db push` melewati migration berdasarkan
-- VERSI (038/039 sudah tercatat), bukan isi berkas. Bila suatu saat CLI
-- mengeluhkan riwayat tak cocok, selaraskan dengan `supabase migration repair`.
-- ============================================================

-- ── 1. Enum helper (jika belum ada) ─────────────────────────

DO $$ BEGIN
  CREATE TYPE extra_type AS ENUM ('optional', 'required');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE extra_selection_type AS ENUM ('single', 'multiple');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── 2. menu_extras ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS menu_extras (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id      UUID NOT NULL REFERENCES outlets(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  type           extra_type NOT NULL DEFAULT 'optional',
  selection_type extra_selection_type NOT NULL DEFAULT 'single',
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_menu_extras_outlet ON menu_extras(outlet_id);

ALTER TABLE menu_extras ENABLE ROW LEVEL SECURITY;

CREATE POLICY "extras_select_auth" ON menu_extras
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "extras_select_anon" ON menu_extras
  FOR SELECT TO anon USING (is_active = TRUE);

CREATE POLICY "extras_insert" ON menu_extras
  FOR INSERT TO authenticated WITH CHECK (TRUE);

CREATE POLICY "extras_update" ON menu_extras
  FOR UPDATE TO authenticated USING (TRUE);

CREATE POLICY "extras_delete" ON menu_extras
  FOR DELETE TO authenticated USING (TRUE);

-- ── 3. menu_extra_options ────────────────────────────────────

CREATE TABLE IF NOT EXISTS menu_extra_options (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  extra_id   UUID NOT NULL REFERENCES menu_extras(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  price      NUMERIC(12,2) NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_meo_extra ON menu_extra_options(extra_id);

ALTER TABLE menu_extra_options ENABLE ROW LEVEL SECURITY;

CREATE POLICY "meo_select_auth" ON menu_extra_options
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "meo_select_anon" ON menu_extra_options
  FOR SELECT TO anon USING (TRUE);

CREATE POLICY "meo_insert" ON menu_extra_options
  FOR INSERT TO authenticated WITH CHECK (TRUE);

CREATE POLICY "meo_update" ON menu_extra_options
  FOR UPDATE TO authenticated USING (TRUE);

CREATE POLICY "meo_delete" ON menu_extra_options
  FOR DELETE TO authenticated USING (TRUE);

-- ── 4. menu_item_extras (junction table) ────────────────────

CREATE TABLE IF NOT EXISTS menu_item_extras (
  menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  extra_id     UUID NOT NULL REFERENCES menu_extras(id) ON DELETE CASCADE,
  PRIMARY KEY (menu_item_id, extra_id)
);

CREATE INDEX IF NOT EXISTS idx_mie_item  ON menu_item_extras(menu_item_id);
CREATE INDEX IF NOT EXISTS idx_mie_extra ON menu_item_extras(extra_id);

ALTER TABLE menu_item_extras ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mie_select_auth" ON menu_item_extras
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "mie_select_anon" ON menu_item_extras
  FOR SELECT TO anon USING (TRUE);

CREATE POLICY "mie_insert" ON menu_item_extras
  FOR INSERT TO authenticated WITH CHECK (TRUE);

CREATE POLICY "mie_delete" ON menu_item_extras
  FOR DELETE TO authenticated USING (TRUE);

-- ── 5. Grant view refresh ────────────────────────────────────

GRANT SELECT ON menu_extras TO authenticated, anon;
GRANT SELECT ON menu_extra_options TO authenticated, anon;
GRANT SELECT ON menu_item_extras TO authenticated, anon;

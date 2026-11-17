-- ============================================================
-- 006_storage.sql
-- Storage buckets dan policies
-- ============================================================

-- Buat bucket untuk gambar menu (public)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'menu-images',
  'menu-images',
  true,
  5242880,  -- 5 MB
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Buat bucket untuk QR code (public)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'qr-codes',
  'qr-codes',
  true,
  1048576,  -- 1 MB
  ARRAY['image/png']
)
ON CONFLICT (id) DO NOTHING;

-- ── Storage Policies: menu-images ────────────────────────────
-- Siapa saja bisa lihat (menu public)
CREATE POLICY "menu_images_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'menu-images');

-- Upload hanya untuk authenticated (admin/owner)
CREATE POLICY "menu_images_auth_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
  );

-- Update/delete hanya untuk authenticated
CREATE POLICY "menu_images_auth_update"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "menu_images_auth_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'menu-images'
    AND auth.role() = 'authenticated'
  );

-- ── Storage Policies: qr-codes ───────────────────────────────
-- QR code bisa dilihat siapa saja (dipakai pelanggan)
CREATE POLICY "qr_codes_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'qr-codes');

-- Hanya service role (Edge Function) yang bisa upload
-- Policy ini otomatis terpenuhi karena Edge Function pakai service_role key
CREATE POLICY "qr_codes_service_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'qr-codes'
    AND auth.role() = 'authenticated'
  );

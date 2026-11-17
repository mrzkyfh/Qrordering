-- Supabase Storage replaces Assets Worker; retain active management-role and outlet checks.
BEGIN;

DROP POLICY IF EXISTS "menu_images_auth_insert" ON storage.objects;
CREATE POLICY "menu_images_auth_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'menu-images'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = (SELECT auth.uid()) AND p.is_active
        AND p.role IN ('owner', 'admin', 'manajer')
        AND (p.role = 'owner' OR (storage.foldername(name))[1] = p.outlet_id::text)
    ))
;

DROP POLICY IF EXISTS "menu_images_auth_update" ON storage.objects;
CREATE POLICY "menu_images_auth_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'menu-images'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = (SELECT auth.uid()) AND p.is_active
        AND p.role IN ('owner', 'admin', 'manajer')
        AND (p.role = 'owner' OR (storage.foldername(name))[1] = p.outlet_id::text)
    ))
  WITH CHECK (bucket_id = 'menu-images'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = (SELECT auth.uid()) AND p.is_active
        AND p.role IN ('owner', 'admin', 'manajer')
        AND (p.role = 'owner' OR (storage.foldername(name))[1] = p.outlet_id::text)
    ))
;

DROP POLICY IF EXISTS "menu_images_auth_delete" ON storage.objects;
CREATE POLICY "menu_images_auth_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'menu-images'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = (SELECT auth.uid()) AND p.is_active
        AND p.role IN ('owner', 'admin', 'manajer')
        AND (p.role = 'owner' OR (storage.foldername(name))[1] = p.outlet_id::text)
    ))
;

COMMIT;

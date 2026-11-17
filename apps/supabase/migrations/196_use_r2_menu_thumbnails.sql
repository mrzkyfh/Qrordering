-- ============================================================
-- 196 — Gunakan thumbnail WebP R2 untuk menu yang sudah dimigrasikan
--
-- File asli tetap berada di `assets/menu/...`. Hanya referensi 31 menu yang
-- checksum thumbnail-nya sudah diverifikasi yang diarahkan ke
-- `assets/menu-thumbs/...`, sehingga data transaksi tidak disentuh.
-- ============================================================

BEGIN;

UPDATE public.menu_items
SET image_url = regexp_replace(
      image_url,
      '/assets/menu/(.+)\.[^./?]+$',
      E'/assets/menu-thumbs/\\1.webp'
    ),
    updated_at = NOW()
WHERE id IN (
    'b26e04d8-378c-4364-a2f2-204886e58f0a',
    'd88e0dcd-fefa-4a51-92a5-c6936919d233',
    'b268fc3a-cc22-4a06-b0c6-780bda5ed0e5',
    '608b9a1f-dab0-456c-9096-630bc5b7c5fb',
    '1cdc76cd-caec-4dcc-9628-ca055cf2dedb',
    '9a1c2d0a-95d3-445f-b316-560244ec8485',
    '90854b31-eee7-4a60-93e0-cabc6f209a37',
    '84111e98-3d64-463c-b530-1bc431114e16',
    'c0692f57-0af7-4b64-9f29-0112ffd03785',
    '066ce421-4364-4640-bd32-1247987b1e65',
    'e1f80ba6-f0b4-48bc-9e29-d3f8f58feaff',
    '99750a2c-8db8-4a47-9dc2-1d8b4e047d8f',
    '13ab50c7-09fa-44f7-89ac-96e8c5d57a53',
    'd4574046-6c90-48ee-bc56-9758cf191547',
    '5cae40b3-0a4f-469a-8f0f-f5b6fe772b26',
    'f0752178-67ac-4cf3-8c2e-a96e4a3cec23',
    'c8c38ccc-c84c-401c-bc1a-93d6f5be58df',
    'b270e6e7-3e06-4f03-989e-1a8f5fc5192b',
    '83f1bdb4-841c-4344-b65f-4e578af1e7b0',
    '058a9d95-8907-47dd-bfe6-461ee0b078dd',
    '571ad32e-d9e7-445d-9145-4520662da890',
    '61a5b6e1-454b-49b6-8e78-24e8ea304db3',
    '15003009-f184-4058-b8f8-7ff983332c52',
    '24e697bf-19e6-40f1-b315-2e9c80a7db09',
    '29370d6d-24dd-4e0f-8511-8d8983ee901b',
    '0aa16d8b-c55c-46a4-acd3-ee4443dbe0e5',
    'df9fbbe8-d012-40b0-ad09-aef03301c398',
    'e304fe0c-a793-421a-8352-2ea6df550805',
    '6494052a-68be-4524-a09d-716d1bbfc43f',
    '413edf17-6d8d-4b27-896c-162aa29c0d45',
    '5b262d9f-e71f-4f19-94f1-36c9480fe377'
  )
  AND image_url LIKE
    'https://qrordering-assets.timess402coffee.workers.dev/assets/menu/%';

COMMIT;

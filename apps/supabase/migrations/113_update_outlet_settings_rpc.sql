-- 113_update_outlet_settings_rpc.sql
-- Simpan setelan outlet secara AMAN & TERTARGET dari aplikasi.
--
-- Menambal dua bug pada jalur simpan setelan di mobile:
--
-- (1) SIMPAN DIAM-DIAM GAGAL. Halaman setelan memakai
--     `UPDATE outlets SET settings=... WHERE id=...` lalu menganggap "tidak ada
--     exception" = berhasil. Padahal saat RLS menyaring barisnya (mis. kasir,
--     yang memang tidak berhak), UPDATE cocok 0 baris dan PostgREST membalas
--     SUKSES — bukan error. Kasir melihat notifikasi "tersimpan" padahal tidak
--     ada yang berubah. Di sini ketidakberhakan dijadikan EXCEPTION yang jelas.
--
-- (2) MENIMPA PERUBAHAN ORANG LAIN. Halaman memuat seluruh JSON `settings` saat
--     dibuka lalu menulis balik seluruh blob saat simpan. Perubahan apa pun dari
--     owner-panel di sela itu (mis. admin lain mengubah logo struk) terhapus
--     tanpa jejak. RPC ini hanya me-MERGE kunci yang benar-benar diubah
--     (`settings || p_patch`), jadi kunci lain tak pernah tersentuh.
--
-- Wewenang sengaja dicocokkan PERSIS dengan policy `outlets_update` (021):
-- owner, atau admin pada outletnya sendiri. RPC ini SECURITY DEFINER (agar bisa
-- membedakan "tidak berhak" dari "0 baris"), sehingga pemeriksaan itu wajib
-- eksplisit di sini — tanpa itu, RPC ini menjadi jalan pintas menembus RLS.

CREATE OR REPLACE FUNCTION public.update_outlet_settings(
  p_outlet_id UUID,
  p_patch     JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
BEGIN
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'Patch setelan harus berupa objek JSON'
      USING ERRCODE = '22023';
  END IF;

  -- COALESCE wajib: is_owner()/auth_role() mengembalikan NULL (bukan false) bila
  -- pemanggil tak punya baris profiles — mis. JWT valid milik staf yang sudah
  -- dihapus. Tanpa COALESCE, ekspresinya jadi NULL, `IF NOT NULL` diperlakukan
  -- sebagai false, dan pemeriksaan ini TERLEWAT diam-diam. Fungsi ini SECURITY
  -- DEFINER (menembus RLS), jadi terlewat = siapa pun bisa mengubah setelan
  -- outlet mana pun.
  -- auth_role() bertipe enum user_role → cast ke text sebelum COALESCE.
  IF NOT (
       COALESCE(is_owner(), false)
       OR (COALESCE(auth_role()::text, '') = 'admin'
           AND auth_outlet_id() IS NOT DISTINCT FROM p_outlet_id)
     ) THEN
    RAISE EXCEPTION 'Tidak berwenang mengubah setelan outlet ini'
      USING ERRCODE = '42501';   -- insufficient_privilege
  END IF;

  UPDATE public.outlets
     SET settings = COALESCE(settings, '{}'::jsonb) || p_patch
   WHERE id = p_outlet_id
  RETURNING settings INTO v_settings;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Outlet tidak ditemukan' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_settings;
END;
$$;

COMMENT ON FUNCTION public.update_outlet_settings(UUID, JSONB) IS
  'Merge setelan outlet (settings || patch) dengan cek wewenang eksplisit '
  '(owner, atau admin outlet itu). Melempar 42501 bila tidak berhak — supaya '
  'aplikasi tidak lagi salah melaporkan "tersimpan" saat RLS menolak. Hanya '
  'kunci di dalam patch yang tersentuh, jadi tidak menimpa perubahan bersamaan.';

REVOKE EXECUTE ON FUNCTION public.update_outlet_settings(UUID, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_outlet_settings(UUID, JSONB) TO authenticated;

-- 209_remove_self_order_per_table_limit.sql
--
-- Hapus batas 15 self-order aktif per meja. Proteksi lain tetap berlaku:
-- qr_token wajib valid, request id idempoten, cooldown 15 detik, serta batas
-- ukuran item/quantity/options. Tidak ada data atau URL QR yang diubah.
           DO $$
DECLARE
  v_signature REGPROCEDURE :=
    'public.create_self_order(uuid,uuid,jsonb,text,text,text,uuid,integer)'::REGPROCEDURE;
  v_definition TEXT;
  v_updated TEXT;
  v_start INTEGER;
  v_tail INTEGER;
  v_end_marker CONSTANT TEXT :=
    E'RAISE EXCEPTION ''Meja ini punya terlalu banyak pesanan aktif. Panggil kasir.'';\n  END IF;';
BEGIN
  SELECT pg_get_functiondef(v_signature) INTO v_definition;

  v_start := strpos(v_definition, 'SELECT count(*) INTO v_active');
  IF v_start = 0 THEN
    RAISE EXCEPTION
      'Awal blok limit 15 self-order tidak ditemukan; migration dihentikan';
  END IF;

  v_tail := strpos(substring(v_definition FROM v_start), v_end_marker);
  IF v_tail = 0 THEN
    RAISE EXCEPTION
      'Akhir blok limit 15 self-order tidak ditemukan; migration dihentikan';
  END IF;

  v_updated := overlay(
    v_definition
    PLACING ''
    FROM v_start
    FOR v_tail + length(v_end_marker) - 1
  );

  IF v_updated = v_definition THEN
    RAISE EXCEPTION
      'Blok limit 15 self-order tidak ditemukan; hentikan migration agar fungsi tidak berubah diam-diam';
  END IF;

  EXECUTE v_updated;
END;
$$;

-- Implementasi delapan argumen tetap internal; seluruh akses publik harus
-- melewati wrapper yang memvalidasi qr_token dan request_id.
REVOKE ALL ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.create_self_order(
  UUID, UUID, JSONB, TEXT, TEXT, TEXT, UUID, INTEGER
) IS
  'Self-order internal tanpa batas jumlah order aktif per meja; harga dan total tetap dihitung server.';

-- 214_remove_qr_order_capacity_limits.sql
--
-- Hapus batas JUMLAH ORDER QR aktif per meja.
-- Batas keamanan satu request (maksimal baris menu, quantity, dan opsi) tetap
-- dipertahankan agar endpoint publik tidak dapat dipakai menghabiskan resource.
-- Cooldown 15 detik tetap dipertahankan untuk mencegah submit ganda cepat.
-- Token dan URL QR meja tidak disentuh.

CREATE OR REPLACE FUNCTION public.enforce_self_order_enabled()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings JSONB;
  v_now TIME;
  v_open TIME;
  v_close TIME;
  v_enabled BOOLEAN;
  v_schedule BOOLEAN;
  v_require_name BOOLEAN;
  v_allow_notes BOOLEAN;
  v_auto_confirm BOOLEAN;
BEGIN
  IF NEW.order_type <> 'self_order' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(settings, '{}'::JSONB)
    INTO v_settings
  FROM public.outlets
  WHERE id = NEW.outlet_id;

  v_enabled := COALESCE((v_settings->>'self_order_enabled')::BOOLEAN, true);
  IF NOT v_enabled THEN
    RAISE EXCEPTION 'Pesanan online sedang ditutup'
      USING ERRCODE = '55000';
  END IF;

  v_schedule := COALESCE(
    (v_settings->>'self_order_schedule_enabled')::BOOLEAN,
    false
  );
  IF v_schedule THEN
    v_now := (now() AT TIME ZONE 'Asia/Jakarta')::TIME;
    v_open := CASE
      WHEN (v_settings->>'self_order_open_time') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        THEN (v_settings->>'self_order_open_time')::TIME
      ELSE TIME '10:00'
    END;
    v_close := CASE
      WHEN (v_settings->>'self_order_close_time') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        THEN (v_settings->>'self_order_close_time')::TIME
      ELSE TIME '22:00'
    END;

    IF v_open <> v_close AND NOT (
      CASE
        WHEN v_open < v_close THEN v_now >= v_open AND v_now < v_close
        ELSE v_now >= v_open OR v_now < v_close
      END
    ) THEN
      RAISE EXCEPTION '%', COALESCE(
        NULLIF(v_settings->>'self_order_closed_message', ''),
        'Order online sedang tutup. Silakan datang langsung.'
      ) USING ERRCODE = '55000';
    END IF;
  END IF;

  v_require_name := COALESCE(
    (v_settings->>'self_order_require_name')::BOOLEAN,
    false
  );
  IF v_require_name AND NULLIF(BTRIM(NEW.customer_name), '') IS NULL THEN
    RAISE EXCEPTION 'Nama pelanggan wajib diisi untuk order online'
      USING ERRCODE = '22023';
  END IF;

  v_allow_notes := COALESCE(
    (v_settings->>'self_order_allow_notes')::BOOLEAN,
    true
  );
  IF NOT v_allow_notes THEN
    NEW.notes := NULL;
  END IF;

  v_auto_confirm := COALESCE(
    (v_settings->>'self_order_auto_confirm')::BOOLEAN,
    false
  );
  IF v_auto_confirm THEN
    NEW.status := 'confirmed';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_self_order_enabled() FROM PUBLIC;

-- Migration 209 menghapus hitungan maksimal order aktif. Blok ini membuat
-- migration tetap idempoten di environment yang belum pernah menerapkan 209.
-- Cooldown anti-double-submit dan idempotensi request tidak diubah.
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
  v_updated := v_definition;

  -- Tetap idempoten bila migration 209 belum pernah diterapkan di environment
  -- baru: hilangkan hanya blok hitungan order aktif per meja.
  v_start := strpos(v_updated, 'SELECT count(*) INTO v_active');
  IF v_start > 0 THEN
    v_tail := strpos(substring(v_updated FROM v_start), v_end_marker);
    IF v_tail = 0 THEN
      RAISE EXCEPTION
        'Blok limit order aktif ditemukan tetapi tidak dapat diparse';
    END IF;
    v_updated := overlay(
      v_updated
      PLACING ''
      FROM v_start
      FOR v_tail + length(v_end_marker) - 1
    );
  END IF;

  IF position('Meja ini punya terlalu banyak pesanan aktif' IN v_updated) > 0 THEN
    RAISE EXCEPTION 'Batas jumlah order QR belum terhapus';
  END IF;
  IF v_updated <> v_definition THEN
    EXECUTE v_updated;
  END IF;
END;
$$;

-- Beberapa database live pernah menerapkan versi awal migration 191 yang belum
-- membawa cap opsi ke helper harga final. Tambahkan guard ini secara bedah pada
-- definisi yang sedang aktif agar perbedaan histori deployment tidak menimpa
-- validasi menu/extra lain di fungsi tersebut.
DO $$
DECLARE
  v_signature REGPROCEDURE :=
    'public._self_order_line(uuid,jsonb)'::REGPROCEDURE;
  v_definition TEXT;
  v_updated TEXT;
  v_marker CONSTANT TEXT :=
    'v_option_count := jsonb_array_length(v_options);';
  v_marker_at INTEGER;
BEGIN
  SELECT pg_get_functiondef(v_signature) INTO v_definition;

  IF position('v_option_count > 30' IN v_definition) = 0 THEN
    v_marker_at := position(v_marker IN v_definition);
    IF v_marker_at = 0 THEN
      RAISE EXCEPTION
        'Assignment jumlah opsi tidak ditemukan; migration dihentikan';
    END IF;

    v_updated := overlay(
      v_definition
      PLACING v_marker || E'\n  IF v_option_count > 30 THEN\n'
        || E'    RAISE EXCEPTION ''Maksimal 30 opsi per item''\n'
        || E'      USING ERRCODE = ''22023'';\n'
        || E'  END IF;'
      FROM v_marker_at
      FOR length(v_marker)
    );
    EXECUTE v_updated;
  END IF;
END;
$$;

-- Guard deployment: migration ini tidak boleh secara tidak sengaja membuka
-- payload publik tanpa batas. Batas berikut adalah proteksi per request, bukan
-- batas jumlah order pelanggan per meja.
DO $$
DECLARE
  v_item_limit_definition TEXT;
  v_line_definition TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'public.enforce_order_item_limits()'::REGPROCEDURE
  ) INTO v_item_limit_definition;
  SELECT pg_get_functiondef(
    'public._self_order_line(uuid,jsonb)'::REGPROCEDURE
  ) INTO v_line_definition;

  -- Periksa enforcement final di trigger/helper, bukan teks pesan wrapper.
  -- Wrapper self-order telah beberapa kali berubah signature dan kalimat error,
  -- sedangkan kedua fungsi ini adalah batas kanonik yang benar-benar menjaga
  -- seluruh INSERT order_items dan validasi opsi QR.
  IF position('quantity' IN lower(v_item_limit_definition)) = 0
     OR position('100' IN v_item_limit_definition) = 0
     OR position('50' IN v_item_limit_definition) = 0
     OR position('option_count' IN lower(v_line_definition)) = 0
     OR position('30' IN v_line_definition) = 0
     OR NOT EXISTS (
       SELECT 1
       FROM pg_trigger trigger_row
       WHERE trigger_row.tgrelid = 'public.order_items'::REGCLASS
         AND trigger_row.tgname = 'trg_enforce_order_item_limits'
         AND trigger_row.tgenabled <> 'D'
         AND trigger_row.tgfoid =
           'public.enforce_order_item_limits()'::REGPROCEDURE
     ) THEN
    RAISE EXCEPTION
      'Batas keamanan payload QR tidak lengkap; migration dihentikan';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.enforce_self_order_enabled() IS
  'Kontrol jadwal dan konfigurasi QR tanpa batas jumlah order aktif per meja.';

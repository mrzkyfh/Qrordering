-- ============================================================
-- 077_set_pin_same_level.sql
-- Ubah aturan set_staff_pin sesuai spesifikasi bisnis final:
--   "tiap role boleh atur PIN level SENDIRI ke bawah" (termasuk sesama level).
--
--   Owner   → Owner, Admin, Manajer, Kasir
--   Admin   → Admin, Manajer, Kasir
--   Manajer → Manajer, Kasir
--   Kasir   → Kasir
--
-- Sebelumnya (068 T-5) memakai strict-greater (rank caller HARUS lebih tinggi),
-- sehingga sesama level tidak bisa. Sekarang dilonggarkan jadi rank >= target.
--
-- CATATAN KEAMANAN (diterima sbg keputusan bisnis): sesama level kini bisa
-- saling reset PIN → potensi pengambilalihan akun lateral antar role setara.
-- Guard outlet (non-owner wajib outlet sama) tetap dipertahankan.
-- ============================================================

CREATE OR REPLACE FUNCTION set_staff_pin(p_target UUID, p_pin TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_caller_role   user_role;
  v_caller_outlet UUID;
  v_target_role   user_role;
  v_target_outlet UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi';
  END IF;

  SELECT role, outlet_id INTO v_caller_role, v_caller_outlet
  FROM profiles WHERE id = auth.uid();

  SELECT role, outlet_id INTO v_target_role, v_target_outlet
  FROM profiles WHERE id = p_target;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Staff tidak ditemukan';
  END IF;

  IF p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'PIN harus tepat 4 digit angka';
  END IF;

  -- Ubah PIN sendiri: selalu boleh.
  IF auth.uid() <> p_target THEN
    -- Owner bebas; lainnya boleh untuk level SENDIRI ke bawah (rank >= target).
    IF v_caller_role <> 'owner' AND role_rank(v_caller_role) < role_rank(v_target_role) THEN
      RAISE EXCEPTION 'Tidak berwenang mengatur PIN role di atas Anda';
    END IF;

    -- Selain owner: target wajib di outlet yang sama.
    IF v_caller_role <> 'owner' AND v_target_outlet IS DISTINCT FROM v_caller_outlet THEN
      RAISE EXCEPTION 'Hanya boleh mengatur PIN staf di outlet yang sama';
    END IF;
  END IF;

  UPDATE profiles
  SET pin_hash         = crypt(p_pin, gen_salt('bf')),
      pin_failed_count = 0,
      pin_failed_at    = NULL,
      updated_at       = NOW()
  WHERE id = p_target;
END;
$$;

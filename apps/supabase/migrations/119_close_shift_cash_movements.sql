-- 119_close_shift_cash_movements.sql
-- expected_cash WAJIB memperhitungkan kas masuk/keluar manual — kalau tidak,
-- kasir terlihat kurang setor padahal uangnya dipakai untuk keperluan outlet.
--
-- MASALAH. Ada DUA implementasi tutup shift dengan rumus BERBEDA:
--   • owner-panel → RPC close_shift : expected = opening + penjualan_tunai
--   • mobile       → UPDATE langsung : opening + penjualan_tunai + kas_masuk_keluar
-- RPC ini tidak menghitung cash_movements sama sekali. Konkretnya: kasir ambil
-- Rp 200.000 dari laci untuk beli galon (tercatat sebagai cash out). Shift
-- ditutup dari HP → selisih nol, benar. Ditutup dari owner-panel → selisih
-- MINUS Rp 200.000, dan kasir tampak menggelapkan uang.
--
-- Uang yang sah keluar dari laci HARUS mengurangi ekspektasi isi laci. Rumus
-- mobile-lah yang benar; rumus di sini disamakan dengannya — lalu mobile
-- dialihkan memakai RPC ini (lihat perubahan shift_datasource) supaya rumusnya
-- hanya hidup di SATU tempat. Selama ada dua salinan, keduanya akan melenceng
-- lagi; pola yang sama sudah terjadi pada pajak & total order.
--
-- Salinan setia 024 — yang berubah hanya ditandai "◄ 119".
--
-- CATATAN: tetap SECURITY INVOKER seperti aslinya, jadi RLS `shifts` &
-- `cash_movements` yang menegakkan wewenang. `SET search_path` WAJIB ditulis
-- ulang di sini: 061 mengeraskannya lewat ALTER FUNCTION, dan CREATE OR REPLACE
-- tanpa klausa ini akan menghapus hardening tersebut tanpa suara.

CREATE OR REPLACE FUNCTION close_shift(
  p_shift_id UUID,
  p_closing_cash numeric,
  p_notes text DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, extensions   -- ◄ 119 (pertahankan hardening 061)
AS $$
DECLARE
  v_cash_total numeric := 0;
  v_movement_net numeric := 0;         -- ◄ 119
  v_opening_cash numeric := 0;
  v_expected_cash numeric := 0;
  v_cash_difference numeric := 0;
BEGIN
  -- Guard: tolak jika shift sudah ditutup
  IF EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND end_time IS NOT NULL) THEN
    RAISE EXCEPTION 'shift already closed';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM payments p
  JOIN orders o ON o.id = p.order_id
  WHERE o.shift_id = p_shift_id
    AND o.status = 'paid'
    AND p.method = 'cash';

  -- ◄ 119 Kas masuk/keluar manual (petty cash): masuk menambah isi laci, keluar
  -- menguranginya. Tanpa baris ini, pengeluaran sah terbaca sebagai selisih kas
  -- dan dibebankan ke kasir.
  SELECT COALESCE(SUM(CASE WHEN cm.type = 'in' THEN cm.amount ELSE -cm.amount END), 0)
    INTO v_movement_net
  FROM cash_movements cm
  WHERE cm.shift_id = p_shift_id;

  SELECT opening_cash INTO v_opening_cash
  FROM shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  v_expected_cash := v_opening_cash + v_cash_total + v_movement_net;  -- ◄ 119
  v_cash_difference := p_closing_cash - v_expected_cash;

  UPDATE shifts
  SET end_time = NOW(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

COMMENT ON FUNCTION close_shift(UUID, numeric, text) IS
  'Tutup shift & hitung expected_cash di SERVER: opening + penjualan tunai + '
  'kas masuk/keluar manual (petty cash). Satu-satunya sumber rumus kas — mobile '
  'dan owner-panel sama-sama memakainya agar tidak melenceng.';

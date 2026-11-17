-- 147_close_shift_deduct_cash_refund.sql
-- Perbaiki rekonsiliasi laci: close_shift (143) menghitung expected_cash =
-- opening + penjualan tunai + net cash movement, TAPI tidak mengurangi REFUND
-- TUNAI. Padahal refund tunai mengeluarkan uang fisik dari laci → expected_cash
-- kelebihan, dan cash_difference melaporkan selisih kurang (shortage) palsu
-- sebesar nominal refund.
--
-- Atribusi refund ke shift memakai order.shift_id — SAMA dengan cara penjualan
-- tunai diatribusikan di fungsi ini (refunds tidak punya shift_id sendiri).
-- Hanya refund method='cash' yang dikurangi; refund kartu/QRIS tidak menyentuh
-- laci. Ini migrasi MAJU (bukan mengedit 143 yang sudah di produksi).
CREATE OR REPLACE FUNCTION public.close_shift(
  p_shift_id UUID,
  p_closing_cash NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_shift public.shifts%ROWTYPE;
  v_cash_total NUMERIC := 0;
  v_refund_cash NUMERIC := 0;
  v_movement_net NUMERIC := 0;
  v_expected_cash NUMERIC := 0;
  v_cash_difference NUMERIC := 0;
BEGIN
  IF p_closing_cash IS NULL OR p_closing_cash < 0 THEN
    RAISE EXCEPTION 'Uang penutupan shift tidak valid' USING ERRCODE = '22023';
  END IF;

  -- Lock sebelum agregasi. record_cash_movement memakai lock yang sama.
  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  IF v_shift.end_time IS NOT NULL THEN
    RAISE EXCEPTION 'shift already closed' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(p.amount), 0) INTO v_cash_total
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE o.shift_id = p_shift_id
    AND o.status = 'paid'
    AND p.method = 'cash';

  -- Refund TUNAI: uang keluar laci saat pengembalian. Diatribusikan ke shift
  -- lewat order.shift_id, konsisten dengan v_cash_total di atas.
  SELECT COALESCE(SUM(r.amount), 0) INTO v_refund_cash
  FROM public.refunds r
  JOIN public.orders o ON o.id = r.order_id
  WHERE o.shift_id = p_shift_id
    AND r.method = 'cash';

  SELECT COALESCE(SUM(CASE WHEN cm.type = 'in' THEN cm.amount ELSE -cm.amount END), 0)
    INTO v_movement_net
  FROM public.cash_movements cm
  WHERE cm.shift_id = p_shift_id;

  v_expected_cash := v_shift.opening_cash + v_cash_total - v_refund_cash + v_movement_net;
  v_cash_difference := p_closing_cash - v_expected_cash;

  UPDATE public.shifts
  SET end_time = NOW(),
      closing_cash = p_closing_cash,
      expected_cash = v_expected_cash,
      cash_difference = v_cash_difference,
      notes = p_notes
  WHERE id = p_shift_id;
END;
$$;

COMMENT ON FUNCTION public.close_shift(UUID, NUMERIC, TEXT) IS
  'Tutup shift + hitung expected_cash = opening + penjualan tunai - refund tunai '
  '+ net cash movement. Refund tunai diatribusikan via order.shift_id (147).';

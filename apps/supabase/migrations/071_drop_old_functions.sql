-- H-1: Hapus versi lama fungsi yang berpotensi DoS lockout.
--
-- Migration 068 membuat _find_approver(UUID, TEXT) 2-param.
-- Migration 070 membuat _find_approver(UUID, TEXT, UUID DEFAULT NULL) 3-param.
-- Keduanya hidup bersamaan → pemanggil tanpa arg ke-3 bisa masih menghit versi
-- lama yang mengincrement fail_count SEMUA approver sekaligus (DoS lockout).
-- Sama untuk void/refund_order_with_approval versi 3-param lama.
--
-- Setelah DROP ini, hanya tersisa versi baru 3-param dari migration 070.

DROP FUNCTION IF EXISTS public._find_approver(UUID, TEXT);
DROP FUNCTION IF EXISTS public.void_order_with_approval(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.refund_order_with_approval(UUID, TEXT, TEXT);

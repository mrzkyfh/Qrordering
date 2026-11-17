-- assign_order_payment_context adalah helper internal bagi RPC pembayaran
-- atomik. Klien tidak perlu dan tidak boleh memanggilnya langsung karena
-- pemisahan atribusi shift dari pencatatan payment membuka celah kondisi
-- setengah jadi apabila request kedua terputus.

REVOKE ALL ON FUNCTION public.assign_order_payment_context(
  UUID, UUID, BOOLEAN
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.assign_order_payment_context(
  UUID, UUID, BOOLEAN
) TO service_role;

COMMENT ON FUNCTION public.assign_order_payment_context(
  UUID, UUID, BOOLEAN
) IS
  'Helper internal untuk record_pos_payment_with_context; tidak diekspos '
  'langsung ke klien agar atribusi shift dan payment tetap atomik.';

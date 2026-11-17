-- 210_reliable_kitchen_print_claims.sql
--
-- Lease atomik mencegah dua tablet mencetak tiket dapur order yang sama.
-- `kitchen_printed` hanya boleh menjadi true setelah SELURUH batch benar-benar
-- terkirim ke printer; tiket yang masih berada di antrean lokal memperpanjang
-- lease dan baru diselesaikan oleh perangkat pemilik setelah retry berhasil.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS kitchen_print_claimed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS kitchen_print_claimed_by TEXT,
  ADD COLUMN IF NOT EXISTS kitchen_print_claim_expires_at TIMESTAMPTZ;

-- Bersihkan RPC versi audit awal bila berkas 210 pernah dijalankan manual.
-- Fungsi tanpa device-id ini dapat menandai selesai tanpa memiliki lease.
DROP FUNCTION IF EXISTS public.record_kitchen_print(UUID);

CREATE OR REPLACE FUNCTION public.claim_kitchen_print(
  p_order_id UUID,
  p_device_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claimed UUID;
BEGIN
  IF p_order_id IS NULL
     OR length(btrim(COALESCE(p_device_id, ''))) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Identitas klaim cetak tidak valid' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '')
     NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang mencetak tiket dapur' USING ERRCODE = '42501';
  END IF;

  -- Tidak ada pengecualian untuk device yang sama: dua proses paralel pada
  -- tablet yang sama tetap harus menghasilkan tepat satu pemenang. Pemilik
  -- yang masih bekerja memperpanjang lease lewat renew_kitchen_print_claim().
  UPDATE public.orders o
  SET kitchen_print_claimed_at = clock_timestamp(),
      kitchen_print_claimed_by = btrim(p_device_id),
      kitchen_print_claim_expires_at = clock_timestamp() + interval '10 minutes'
  WHERE o.id = p_order_id
    AND o.kitchen_printed = false
    AND (COALESCE(public.is_owner(), false)
         OR o.outlet_id = public.auth_outlet_id())
    AND (o.kitchen_print_claimed_by IS NULL
         OR o.kitchen_print_claim_expires_at IS NULL
         OR o.kitchen_print_claim_expires_at <= clock_timestamp())
  RETURNING o.id INTO v_claimed;

  RETURN v_claimed IS NOT NULL;
END;
$$;

-- Heartbeat sebelum mengirim batch/retry. Hanya pemilik lease yang boleh
-- memperpanjangnya; perangkat lain tidak dapat mengambil alih diam-diam.
CREATE OR REPLACE FUNCTION public.renew_kitchen_print_claim(
  p_order_id UUID,
  p_device_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_renewed UUID;
BEGIN
  IF p_order_id IS NULL
     OR length(btrim(COALESCE(p_device_id, ''))) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Identitas klaim cetak tidak valid' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '')
     NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang mencetak tiket dapur' USING ERRCODE = '42501';
  END IF;

  UPDATE public.orders o
  SET kitchen_print_claim_expires_at = clock_timestamp() + interval '10 minutes'
  WHERE o.id = p_order_id
    AND o.kitchen_printed = false
    AND o.kitchen_print_claimed_by = btrim(p_device_id)
    AND (COALESCE(public.is_owner(), false)
         OR o.outlet_id = public.auth_outlet_id())
  RETURNING o.id INTO v_renewed;
  RETURN v_renewed IS NOT NULL;
END;
$$;

-- Tiket yang sudah aman di antrean persisten perangkat diberi waktu lebih
-- panjang untuk retry. Aplikasi tetap melakukan heartbeat setiap kali retry.
CREATE OR REPLACE FUNCTION public.defer_kitchen_print_claim(
  p_order_id UUID,
  p_device_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deferred UUID;
BEGIN
  IF p_order_id IS NULL
     OR length(btrim(COALESCE(p_device_id, ''))) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Identitas klaim cetak tidak valid' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '')
     NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang mencetak tiket dapur' USING ERRCODE = '42501';
  END IF;

  UPDATE public.orders o
  SET kitchen_print_claim_expires_at = clock_timestamp() + interval '30 minutes'
  WHERE o.id = p_order_id
    AND o.kitchen_printed = false
    AND o.kitchen_print_claimed_by = btrim(p_device_id)
    AND (COALESCE(public.is_owner(), false)
         OR o.outlet_id = public.auth_outlet_id())
  RETURNING o.id INTO v_deferred;
  RETURN v_deferred IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_kitchen_print(
  p_order_id UUID,
  p_device_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_done UUID;
BEGIN
  IF p_order_id IS NULL
     OR length(btrim(COALESCE(p_device_id, ''))) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Identitas klaim cetak tidak valid' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '')
     NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang mencetak tiket dapur' USING ERRCODE = '42501';
  END IF;

  -- Tidak ada jalur bypass: hanya device pemilik klaim yang dapat menandai
  -- selesai. Lease boleh lewat selama belum direbut perangkat lain.
  UPDATE public.orders o
  SET kitchen_printed = true,
      kitchen_print_claimed_at = NULL,
      kitchen_print_claimed_by = NULL,
      kitchen_print_claim_expires_at = NULL
  WHERE o.id = p_order_id
    AND o.kitchen_printed = false
    AND o.kitchen_print_claimed_by = btrim(p_device_id)
    AND (COALESCE(public.is_owner(), false)
         OR o.outlet_id = public.auth_outlet_id())
  RETURNING o.id INTO v_done;
  RETURN v_done IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_kitchen_print_claim(
  p_order_id UUID,
  p_device_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_released UUID;
BEGIN
  IF p_order_id IS NULL
     OR length(btrim(COALESCE(p_device_id, ''))) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Identitas klaim cetak tidak valid' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(public.auth_role()::TEXT, '')
     NOT IN ('owner', 'admin', 'manajer', 'kasir') THEN
    RAISE EXCEPTION 'Tidak berwenang mencetak tiket dapur' USING ERRCODE = '42501';
  END IF;

  UPDATE public.orders o
  SET kitchen_print_claimed_at = NULL,
      kitchen_print_claimed_by = NULL,
      kitchen_print_claim_expires_at = NULL
  WHERE o.id = p_order_id
    AND o.kitchen_printed = false
    AND o.kitchen_print_claimed_by = btrim(p_device_id)
    AND (COALESCE(public.is_owner(), false)
         OR o.outlet_id = public.auth_outlet_id())
  RETURNING o.id INTO v_released;
  RETURN v_released IS NOT NULL;
END;
$$;

-- Bila edit order sengaja membuka kembali status cetak (true -> false), klaim
-- lama juga harus dibuang. Append open-bill tidak mengubah flag ini karena
-- hanya item tambahan yang dicetak oleh jalur khusus aplikasi.
CREATE OR REPLACE FUNCTION public.clear_stale_kitchen_print_claim()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.kitchen_printed = true AND NEW.kitchen_printed = false THEN
    NEW.kitchen_print_claimed_at := NULL;
    NEW.kitchen_print_claimed_by := NULL;
    NEW.kitchen_print_claim_expires_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clear_stale_kitchen_print_claim ON public.orders;
CREATE TRIGGER trg_clear_stale_kitchen_print_claim
  BEFORE UPDATE OF kitchen_printed ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.clear_stale_kitchen_print_claim();

REVOKE ALL ON FUNCTION public.claim_kitchen_print(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.renew_kitchen_print_claim(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.defer_kitchen_print_claim(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_kitchen_print(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_kitchen_print_claim(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_stale_kitchen_print_claim() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.claim_kitchen_print(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.renew_kitchen_print_claim(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.defer_kitchen_print_claim(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_kitchen_print(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_kitchen_print_claim(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.claim_kitchen_print(UUID, TEXT) IS
  'Ambil lease eksklusif tiket dapur; device yang sama pun tidak dapat mengklaim dua kali secara paralel.';
COMMENT ON FUNCTION public.complete_kitchen_print(UUID, TEXT) IS
  'Tandai seluruh batch tiket dapur selesai, khusus device pemilik lease.';

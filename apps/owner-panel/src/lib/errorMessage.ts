/**
 * Ubah error teknis (Postgres/Supabase/network) menjadi pesan yang jelas &
 * ramah untuk pengguna — BUKAN gaya developer.
 *
 * Pakai di handler toast error:
 *   toast({ title: 'Gagal menyimpan', description: humanizeError(err), variant: 'destructive' })
 *
 * Error mentah tetap dicatat ke console untuk debugging developer.
 */
export function humanizeError(err: unknown): string {
  if (err) console.error('[error]', err)

  const e = err as
    | { code?: string; message?: string; details?: string; hint?: string }
    | null
    | undefined
  const code = e?.code
  const haystack = `${e?.message ?? ''} ${e?.details ?? ''}`
  const msg = haystack.toLowerCase()

  // 1) Berdasarkan nama constraint spesifik (paling akurat & jelas)
  const byConstraint: Array<[RegExp, string]> = [
    [/outlet_id_fkey/i, 'Cabang tidak valid atau sudah dihapus. Muat ulang halaman, lalu pilih cabang lagi.'],
    [/chk_promo_percentage_range/i, 'Persentase diskon harus antara 0 dan 100.'],
    [/chk_promo_date_range/i, 'Tanggal selesai harus sama atau setelah tanggal mulai.'],
    [/chk_order_amounts|chk_.*non_negative|chk_.*amount/i, 'Nominal tidak boleh negatif.'],
    [/chk_points_non_negative/i, 'Poin tidak boleh menjadi negatif.'],
    [/expense_date/i, 'Tanggal pengeluaran tidak boleh di masa depan.'],
    [/opening_cash/i, 'Kas awal tidak boleh negatif.'],
    [/order_number|outlet_ordernum/i, 'Nomor transaksi bentrok. Coba lagi.'],
    [/table_number/i, 'Nomor meja itu sudah dipakai di cabang ini.'],
    [/outlet.*name|char_length.*name/i, 'Nama tidak valid (minimal 2 karakter).'],
    [/email/i, 'Email tidak valid atau sudah terdaftar.'],
  ]
  for (const [re, m] of byConstraint) if (re.test(haystack)) return m

  // 2) Berdasarkan kode error Postgres
  switch (code) {
    case '23503':
      return 'Data terkait tidak ditemukan. Muat ulang halaman lalu coba lagi.'
    case '23505':
      return 'Data ini sudah ada. Gunakan nama atau kode yang berbeda.'
    case '23502':
      return 'Ada kolom wajib yang belum diisi.'
    case '23514':
      return 'Nilai yang dimasukkan tidak valid.'
    case '22001':
      return 'Teks yang dimasukkan terlalu panjang.'
    case '22003':
    case '22P02':
      return 'Format atau angka yang dimasukkan tidak valid.'
    case '42501':
      return 'Anda tidak punya izin untuk melakukan aksi ini.'
  }

  // 3) Heuristik dari teks pesan
  if (msg.includes('row-level security') || msg.includes('permission') || msg.includes('not authorized'))
    return 'Anda tidak punya izin untuk melakukan aksi ini.'
  if (msg.includes('duplicate')) return 'Data ini sudah ada. Gunakan nama atau kode yang berbeda.'
  if (msg.includes('foreign key')) return 'Data terkait tidak valid. Muat ulang halaman lalu coba lagi.'
  if (msg.includes('violates check') || msg.includes('check constraint'))
    return 'Nilai yang dimasukkan tidak valid.'
  if (msg.includes('invalid login') || msg.includes('credentials'))
    return 'Email atau password salah.'
  if (msg.includes('jwt') || msg.includes('expired') || msg.includes('session'))
    return 'Sesi Anda berakhir. Silakan login ulang.'
  if (msg.includes('network') || msg.includes('failed to fetch') || msg.includes('fetch'))
    return 'Koneksi bermasalah. Periksa internet Anda lalu coba lagi.'

  // 4) Fallback ramah (tanpa istilah teknis)
  return 'Terjadi kesalahan saat memproses. Coba lagi sebentar.'
}

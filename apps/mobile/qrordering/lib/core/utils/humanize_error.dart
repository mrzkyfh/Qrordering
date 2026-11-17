import 'package:supabase_flutter/supabase_flutter.dart';

/// Ubah error teknis (Postgres/Supabase/jaringan) menjadi pesan yang jelas &
/// ramah untuk pengguna — BUKAN gaya developer.
///
/// Pemakaian:
///   AppToast.error(context, humanizeError(e));
///   AppToast.error(context, humanizeError(e, fallback: 'Gagal menyimpan draf.'));
///
/// [fallback] dipakai jika error tak dikenali — isi dengan kalimat ramah sesuai
/// konteks aksinya.
String humanizeError(
  Object? err, {
  String fallback = 'Terjadi kesalahan. Coba lagi sebentar.',
}) {
  String? code;
  String raw = err?.toString() ?? '';
  if (err is PostgrestException) {
    code = err.code;
    raw = '${err.message} ${err.details ?? ''} ${err.hint ?? ''}';
  } else if (err is AuthException) {
    raw = err.message;
  }
  final msg = raw.toLowerCase();

  // Sesi PIN belum benar-benar berganti dari akun perangkat ke akun staf.
  if (msg.contains('sesi pembayaran tidak sesuai') ||
      msg.contains('sesi staff belum terverifikasi')) {
    return 'Sesi pengguna belum siap. Keluar dari akun staf, masuk kembali dengan PIN, lalu coba pembayaran sekali lagi.';
  }
  // RPC pembayaran mengizinkan owner/admin/manajer/kasir. Penolakan ini berarti
  // identitas sesi atau cabang order tidak cocok, bukan metode bayarnya dilarang.
  if (msg.contains('tidak berwenang membayar order ini') ||
      msg.contains('order tidak ditemukan atau tidak berwenang')) {
    return 'Pembayaran ditolak karena sesi pengguna atau cabang pesanan tidak sesuai. Muat ulang pesanan. Jika masih terjadi, keluar lalu masuk kembali dengan PIN.';
  }

  // Izin / RLS
  if (msg.contains('row-level security') ||
      msg.contains('permission') ||
      msg.contains('not authorized') ||
      code == '42501') {
    return 'Anda tidak punya izin untuk melakukan aksi ini.';
  }
  // Duplikat
  if (code == '23505' || msg.contains('duplicate')) {
    return 'Data ini sudah ada. Gunakan nama atau kode yang berbeda.';
  }
  // Foreign key / data terkait
  if (code == '23503' || msg.contains('foreign key')) {
    return 'Data terkait tidak ditemukan. Muat ulang lalu coba lagi.';
  }
  // Kolom wajib
  if (code == '23502') return 'Ada data wajib yang belum diisi.';
  // Check constraint
  if (code == '23514' ||
      msg.contains('violates check') ||
      msg.contains('check constraint')) {
    return 'Nilai yang dimasukkan tidak valid.';
  }
  // Transisi status order (validator DB)
  if (msg.contains('invalid order status transition')) {
    return 'Status pesanan tidak bisa diubah seperti itu. Muat ulang lalu coba lagi.';
  }
  // Login
  if (msg.contains('invalid login') ||
      msg.contains('invalid credentials') ||
      msg.contains('invalid email')) {
    return 'Email atau password salah.';
  }
  // Sesi
  if (msg.contains('jwt') ||
      msg.contains('expired') ||
      msg.contains('not authenticated') ||
      msg.contains('session')) {
    return 'Sesi Anda berakhir. Silakan login ulang.';
  }
  // Jaringan
  if (msg.contains('socketexception') ||
      msg.contains('clientexception') ||
      msg.contains('failed host lookup') ||
      msg.contains('network') ||
      msg.contains('timeout') ||
      msg.contains('connection') ||
      msg.contains('failed to fetch')) {
    return 'Koneksi bermasalah. Periksa internet Anda lalu coba lagi.';
  }

  return fallback;
}

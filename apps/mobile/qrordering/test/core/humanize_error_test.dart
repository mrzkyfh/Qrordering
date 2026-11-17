import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/core/utils/humanize_error.dart';

void main() {
  group('humanizeError pembayaran', () {
    test('menjelaskan sesi PIN yang tidak sesuai', () {
      final message = humanizeError(
        StateError(
          'Sesi pembayaran tidak sesuai dengan pengguna yang sedang masuk',
        ),
      );

      expect(message, contains('Sesi pengguna belum siap'));
      expect(message, contains('masuk kembali dengan PIN'));
    });

    test('izin pembayaran tidak disamakan dengan larangan role', () {
      final message = humanizeError(
        const PostgrestException(
          message: 'Tidak berwenang membayar order ini',
          code: '42501',
        ),
      );

      expect(message, contains('sesi pengguna atau cabang pesanan'));
      expect(message, isNot(contains('tidak punya izin')));
    });

    test('penolakan RLS lain tetap memakai pesan izin umum', () {
      final message = humanizeError(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      expect(message, 'Anda tidak punya izin untuk melakukan aksi ini.');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('halaman Absensi memiliki tombol kembali ke halaman utama Kasir', () {
    final source = File(
      'lib/features/pos/presentation/pages/attendance_page.dart',
    ).readAsStringSync();

    expect(source, contains("key: const Key('attendance-back-button')"));
    expect(source, contains("tooltip: 'Kembali ke Kasir'"));
    expect(source, contains("onPressed: () => context.go('/kasir')"));
  });
}

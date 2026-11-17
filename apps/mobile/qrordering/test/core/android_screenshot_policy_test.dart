import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android tidak memblokir screenshot aplikasi', () {
    final source = File(
      'android/app/src/main/kotlin/com/qrordering/pos/MainActivity.kt',
    ).readAsStringSync();

    expect(source, isNot(contains('FLAG_SECURE')));
  });
}

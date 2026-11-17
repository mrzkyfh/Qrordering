import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('POS tetap memuat menu aktif yang sedang habis', () async {
    final source = await File(
      'lib/features/pos/data/datasources/pos_datasource.dart',
    ).readAsString();
    final start = source.indexOf('Future<List<MenuItem>> fetchMenuItems');
    final end = source.indexOf('Future<String?> _resolveShiftId', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final section = source.substring(start, end);
    expect(section, contains(".eq('is_active', true)"));
    expect(
      section,
      isNot(contains(".eq('is_available', true)")),
      reason: 'menu habis harus tetap terlihat dengan badge Habis',
    );
  });

  test('preview dan share struk menggunakan snapshot lokal', () async {
    final source = await File(
      'lib/features/orders/presentation/pages/order_list_page.dart',
    ).readAsString();
    final start = source.indexOf('Future<(Order, Map<String, dynamic>)>');
    final end = source.indexOf('// ── Tombol Refund', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final section = source.substring(start, end);
    expect(section, contains('var full = order;'));
    expect(section, contains('cachedOutletReceiptMap'));
    expect(section, contains('ConnectivityService.instance.online.value'));
  });
}

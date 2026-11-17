import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final shell = File(
    'lib/features/pos/presentation/pages/kasir_shell.dart',
  ).readAsStringSync();
  final router = File('lib/core/router/app_router.dart').readAsStringSync();
  final tillResolver = File(
    'lib/features/pos/presentation/widgets/till_resolver.dart',
  ).readAsStringSync();
  final paymentPage = File(
    'lib/features/pos/presentation/pages/payment_page.dart',
  ).readAsStringSync();
  final orderPage = File(
    'lib/features/orders/presentation/pages/order_list_page.dart',
  ).readAsStringSync();
  final shiftPage = File(
    'lib/features/pos/presentation/pages/shift_page.dart',
  ).readAsStringSync();

  test('login kasir tidak membuka atau memaksa shift', () {
    expect(router, contains('KasirSessionHost'));
    expect(shell, isNot(contains('_OpenKasirScreen')));
    expect(shell, contains("title: const Text('Buka Kasir?')"));
    expect(shell, contains("child: const Text('Nanti Saja')"));
    expect(shell, contains("const Text('Buka Kasir')"));
    expect(shell, contains('datasource.openShift('));
    expect(shell, contains('class _KasirLockedView'));
    expect(shell, contains("location == '/kasir'"));
  });

  test('buka kasir tersedia manual dan menu mengikuti status shift', () {
    expect(shell, contains("hasActiveShift ? 'Tutup Kasir' : 'Buka Kasir'"));
    expect(shiftPage, contains("label: const Text('Buka Kasir')"));
    expect(shiftPage, contains("actionLabel: 'Buka Kasir'"));
  });

  test('pembayaran role kasir wajib memakai shift miliknya sendiri', () {
    expect(tillResolver, contains('bool requireOwnShift = false'));
    expect(tillResolver, contains('if (requireOwnShift)'));
    expect(
      tillResolver.indexOf('if (requireOwnShift)'),
      lessThan(tillResolver.lastIndexOf('if (open.isEmpty)')),
    );
    expect(
      RegExp(
        r'requireOwnShift:\s*authState\.profile\.role == UserRole\.kasir',
      ).allMatches(paymentPage).length,
      2,
    );
    expect(
      RegExp(
        r'requireOwnShift:\s*auth(?:State)?\.profile\.role == UserRole\.kasir',
      ).allMatches(orderPage).length,
      2,
    );
  });
}

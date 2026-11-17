import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/widgets/payment_success_dialog.dart';

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    Size size = const Size(360, 720),
    bool offline = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: paymentSuccessDialogForTesting(
            orderNumber: 'KJ-20260725-0001',
            customerName:
                'Nama pelanggan yang sangat panjang untuk menguji tampilan',
            orderType: OrderType.dineIn,
            subtotal: 999999999,
            tax: 99999999,
            service: 19999999,
            total: 1119999997,
            kembalian: 500000,
            offline: offline,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ringkasan pembayaran tetap terbaca pada layar kecil', (
    tester,
  ) async {
    await pumpDialog(tester, size: const Size(320, 568));

    expect(find.text('Pembayaran Berhasil'), findsOneWidget);
    expect(find.text('Kembalian'), findsOneWidget);
    expect(find.text('Selesai'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status transaksi offline dijelaskan dengan benar', (
    tester,
  ) async {
    await pumpDialog(tester, offline: true);

    expect(find.text('Tersimpan (Offline)'), findsOneWidget);
    expect(find.text('⏳ Akan tersinkron saat online'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

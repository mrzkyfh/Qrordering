import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:time420s/features/orders/presentation/pages/penjualan_page.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/order.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('id_ID'));

  testWidgets('transaksi hari sebelumnya menyediakan cetak ulang struk', (
    tester,
  ) async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final order = Order(
      id: 'order-yesterday',
      outletId: 'outlet-1',
      orderNumber: '006',
      orderType: OrderType.dineIn,
      status: OrderStatus.paid,
      customerName: 'Tanpa Pelanggan',
      subtotal: 50000,
      discountAmount: 0,
      taxAmount: 5000,
      serviceCharge: 1000,
      totalAmount: 56000,
      stockDeducted: true,
      createdAt: yesterday,
      updatedAt: yesterday,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: saleActionsSheetForTesting(order: order, cashierName: 'Dino M'),
        ),
      ),
    );

    expect(find.text('Transaksi #006'), findsOneWidget);
    expect(find.text('Dino M'), findsOneWidget);
    expect(find.byKey(const Key('sale-reprint-receipt')), findsOneWidget);
    expect(find.text('Cetak Ulang Struk'), findsOneWidget);
    expect(find.byKey(const Key('sale-partial-refund')), findsOneWidget);
    expect(find.text('Refund Sebagian'), findsOneWidget);
    expect(find.text('Refund Transaksi'), findsOneWidget);
  });

  testWidgets('detail penjualan menampilkan waktu bayar, bukan waktu order', (
    tester,
  ) async {
    final createdAt = DateTime(2026, 7, 29, 11, 6);
    final paidAt = DateTime(2026, 7, 30, 10, 23);
    final order = Order(
      id: 'order-paid-later',
      outletId: 'outlet-1',
      orderNumber: '008',
      orderType: OrderType.dineIn,
      status: OrderStatus.paid,
      subtotal: 30000,
      discountAmount: 0,
      taxAmount: 3000,
      serviceCharge: 600,
      totalAmount: 33600,
      stockDeducted: true,
      createdAt: createdAt,
      updatedAt: paidAt,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: saleActionsSheetForTesting(
            order: order,
            cashierName: 'Kasir',
            salesAt: paidAt,
          ),
        ),
      ),
    );

    expect(find.text('30 Jul 2026, 10:23'), findsOneWidget);
    expect(find.text('29 Jul 2026, 11:06'), findsNothing);
  });
}

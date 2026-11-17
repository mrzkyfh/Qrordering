import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/orders/presentation/widgets/void_order_dialog.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/order.dart';

Order _order() {
  final now = DateTime(2026, 7, 25);
  return Order(
    id: 'order-1',
    outletId: 'outlet-1',
    orderNumber: 'KJ-001',
    orderType: OrderType.dineIn,
    status: OrderStatus.paid,
    subtotal: 100000,
    discountAmount: 0,
    taxAmount: 10000,
    serviceCharge: 2000,
    totalAmount: 112000,
    stockDeducted: true,
    createdAt: now,
    updatedAt: now,
  );
}

const _staff = [
  {
    'id': 'manager-1',
    'full_name': 'Manajer Utama',
    'role': 'manajer',
    'has_pin': true,
    'can_refund': true,
  },
  {
    'id': 'manager-locked',
    'full_name': 'Manajer Tanpa Akses',
    'role': 'manajer',
    'has_pin': true,
    'can_refund': false,
  },
  {
    'id': 'cashier-1',
    'full_name': 'Kasir Tidak Berwenang',
    'role': 'kasir',
    'has_pin': true,
    'can_refund': false,
  },
  {
    'id': 'admin-no-pin',
    'full_name': 'Admin Tanpa PIN',
    'role': 'admin',
    'has_pin': false,
    'can_refund': true,
  },
];

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required OrderActionType action,
    required OrderActionStaffLoader loader,
    Size size = const Size(360, 720),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: orderActionDialogForTesting(
            order: _order(),
            action: action,
            loadStaff: loader,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('refund memakai label yang tepat dan menyaring pemberi izin', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      action: OrderActionType.refund,
      loader: (_) async => _staff,
    );

    expect(find.text('Refund Pesanan'), findsOneWidget);
    expect(find.text('Alasan Refund'), findsOneWidget);
    expect(find.text('Alasan Pembatalan'), findsNothing);

    await tester.tap(find.text('Pilih staff'));
    await tester.pump();
    expect(find.text('Manajer Utama'), findsOneWidget);
    expect(find.text('Manajer Tanpa Akses'), findsOneWidget);
    expect(find.text('Tidak memiliki akses refund'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('Kasir Tidak Berwenang'), findsNothing);
    expect(find.text('Admin Tanpa PIN'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'approver tanpa akses refund terlihat tetapi tidak dapat dipilih',
    (tester) async {
      await pumpDialog(
        tester,
        action: OrderActionType.refund,
        loader: (_) async => _staff,
      );

      await tester.tap(find.text('Pilih staff'));
      await tester.pump();
      await tester.tap(find.text('Manajer Tanpa Akses'));
      await tester.pump();

      expect(find.text('Pilih staff'), findsOneWidget);
      expect(find.text('Konfirmasi Refund'), findsOneWidget);
      expect(find.text('Manajer Tanpa Akses'), findsOneWidget);
    },
  );

  testWidgets('kasir peminta tidak diperiksa oleh dialog refund', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      action: OrderActionType.refund,
      loader: (_) async => _staff,
    );

    expect(find.text('Refund Pesanan'), findsOneWidget);
    expect(find.text('Pilih staff'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'gagal memuat pemberi izin dapat dicoba ulang tanpa dialog buntu',
    (tester) async {
      var attempts = 0;
      await pumpDialog(
        tester,
        action: OrderActionType.voidOrder,
        loader: (_) async {
          attempts++;
          if (attempts == 1) throw Exception('jaringan terputus');
          return _staff;
        },
      );

      expect(find.textContaining('belum dapat dimuat'), findsOneWidget);
      expect(find.text('Coba Lagi'), findsOneWidget);
      expect(find.textContaining('Tidak ada staf'), findsNothing);

      await tester.tap(find.text('Coba Lagi'));
      await tester.pump();
      await tester.pump();
      expect(attempts, 2);
      expect(find.textContaining('belum dapat dimuat'), findsNothing);
      expect(find.text('Pilih staff'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dialog void tidak overflow pada layar kasir kecil', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      action: OrderActionType.voidOrder,
      loader: (_) async => _staff,
      size: const Size(320, 568),
    );

    expect(find.text('Batalkan Pesanan'), findsOneWidget);
    expect(find.text('Konfirmasi Void'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

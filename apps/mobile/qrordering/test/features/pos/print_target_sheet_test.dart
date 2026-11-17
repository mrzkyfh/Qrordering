import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/pos/presentation/widgets/print_target_sheet.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/order.dart';
import 'package:qrordering/shared/services/kitchen_print.dart';
import 'package:qrordering/shared/services/printer_service.dart';

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    Future<KitchenPrintResult> Function({
      required String orderId,
      required String outletId,
      bool force,
      String? printedBy,
    })?
    printKitchen,
    Future<bool> Function(String, String, String?)? printReceipt,
    Order? orderSnapshot,
    Future<Order?> Function(Order)? loadManualKitchenOrder,
    Future<KitchenPrintResult> Function(List<OrderItem>, String)?
    printSelectedItems,
    List<SavedPrinter>? initialKitchenPrinters,
    Size size = const Size(360, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: printTargetSheetForTesting(
            orderId: 'order-1',
            outletId: 'outlet-1',
            cashierName: 'Kasir',
            printReceipt: printReceipt ?? (_, _, _) async => true,
            printKitchen: printKitchen,
            orderSnapshot: orderSnapshot,
            loadManualKitchenOrder: loadManualKitchenOrder,
            printSelectedItems: printSelectedItems,
            initialKitchenPrinters: initialKitchenPrinters,
          ),
        ),
      ),
    );
  }

  testWidgets('hasil cetak dapur menampilkan jumlah tiket sebenarnya', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      printKitchen:
          ({
            required orderId,
            required outletId,
            force = false,
            printedBy,
          }) async => const KitchenPrintResult(printed: 2),
    );

    await tester.tap(find.text('Tiket Dapur'));
    await tester.pumpAndSettle();

    expect(find.text('2 tiket dapur tercetak.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('antrean cetak tidak dilaporkan sebagai tercetak', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      printKitchen:
          ({
            required orderId,
            required outletId,
            force = false,
            printedBy,
          }) async => const KitchenPrintResult(queued: 3),
    );

    await tester.tap(find.text('Tiket Dapur'));
    await tester.pumpAndSettle();

    expect(find.text('3 tiket dapur masuk antrean cetak.'), findsOneWidget);
    expect(find.textContaining('tercetak'), findsNothing);
  });

  testWidgets('alasan tiket dilewati ditampilkan sebagai kegagalan', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      printKitchen:
          ({
            required orderId,
            required outletId,
            force = false,
            printedBy,
          }) async => const KitchenPrintResult(
            skippedReason: 'Belum ada printer dapur aktif',
          ),
    );

    await tester.tap(find.text('Tiket Dapur'));
    await tester.pumpAndSettle();

    expect(find.text('Belum ada printer dapur aktif'), findsOneWidget);
  });

  testWidgets('gagal cetak struk kasir memberikan pesan yang jelas', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      printReceipt: (_, _, _) async => false,
      printKitchen:
          ({
            required orderId,
            required outletId,
            force = false,
            printedBy,
          }) async => const KitchenPrintResult(),
      size: const Size(320, 568),
    );

    await tester.tap(find.text('Struk Kasir'));
    await tester.pumpAndSettle();

    expect(find.text('Gagal cetak struk kasir'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'paid snapshot ringkas dimuat lengkap lalu mencetak sekali ke target terpilih',
    (tester) async {
      final time = DateTime(2026, 10, 9, 10);
      final compact = Order(
        id: 'paid-order',
        outletId: 'outlet-1',
        orderNumber: 'P-001',
        orderType: OrderType.dineIn,
        status: OrderStatus.paid,
        subtotal: 40000,
        discountAmount: 0,
        taxAmount: 0,
        serviceCharge: 0,
        totalAmount: 40000,
        stockDeducted: true,
        createdAt: time,
        updatedAt: time,
        payments: [
          Payment(
            id: 'payment-1',
            orderId: 'paid-order',
            outletId: 'outlet-1',
            method: PaymentMethod.cash,
            amount: 40000,
            paidAt: time,
          ),
        ],
      );
      MenuItem menu(String id, String name) => MenuItem(
        id: id,
        outletId: 'outlet-1',
        categoryId: id == 'menu-food' ? 'food' : 'bar',
        name: name,
        price: 20000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      );
      OrderItem item(String id, String menuId, String name) => OrderItem(
        id: id,
        orderId: compact.id,
        menuItemId: menuId,
        quantity: 1,
        unitPrice: 20000,
        subtotal: 20000,
        menuItem: menu(menuId, name),
      );
      final complete = Order(
        id: compact.id,
        outletId: compact.outletId,
        orderNumber: compact.orderNumber,
        orderType: compact.orderType,
        status: compact.status,
        subtotal: compact.subtotal,
        discountAmount: compact.discountAmount,
        taxAmount: compact.taxAmount,
        serviceCharge: compact.serviceCharge,
        totalAmount: compact.totalAmount,
        stockDeducted: compact.stockDeducted,
        createdAt: compact.createdAt,
        updatedAt: compact.updatedAt,
        items: [
          item('food-item', 'menu-food', 'Nasi Goreng'),
          item('bar-item', 'menu-bar', 'Es Teh'),
        ],
      );
      var loads = 0;
      var calls = 0;
      String? target;
      List<OrderItem>? payload;

      await pumpSheet(
        tester,
        size: const Size(720, 900),
        orderSnapshot: compact,
        loadManualKitchenOrder: (snapshot) async {
          loads++;
          expect(snapshot.id, compact.id);
          return complete;
        },
        initialKitchenPrinters: const [
          SavedPrinter(
            id: 'kitchen-food',
            name: 'Dapur',
            dapurEnabled: true,
            categories: ['food'],
          ),
          SavedPrinter(
            id: 'kitchen-bar',
            name: 'Bar',
            dapurEnabled: true,
            categories: ['bar'],
          ),
        ],
        printSelectedItems: (items, printerId) async {
          calls++;
          target = printerId;
          payload = items;
          return const KitchenPrintResult(printed: 1);
        },
      );

      await tester.tap(find.text('Tiket Dapur'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('Nasi Goreng'), findsOneWidget);
      expect(find.text('Es Teh'), findsOneWidget);

      await tester.tap(find.byKey(const Key('kitchen-target-printer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dapur').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Tambah jumlah').first);
      await tester.pump();
      await tester.tap(find.text('Cetak 1 Item Terpilih'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(target, 'kitchen-food');
      expect(payload, hasLength(1));
      expect(payload!.single.menuItem?.name, 'Nasi Goreng');
      expect(compact.status, OrderStatus.paid);
      expect(compact.totalAmount, 40000);
      expect(compact.stockDeducted, true);
      expect(compact.payments, hasLength(1));
      expect(compact.payments!.single.amount, 40000);
      expect(compact.items, isNull);
    },
  );
}

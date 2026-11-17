import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/orders/presentation/widgets/kitchen_item_print_dialog.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/menu_item.dart';
import 'package:time420s/shared/models/order.dart';
import 'package:time420s/shared/services/kitchen_print.dart';
import 'package:time420s/shared/services/printer_service.dart';

MenuItem _menu(String id, String name) => MenuItem(
  id: id,
  outletId: 'outlet-1',
  categoryId: 'category-1',
  name: name,
  price: 20000,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  sortOrder: 0,
);

OrderItem _item(String id, String name, int quantity) => OrderItem(
  id: id,
  orderId: 'order-1',
  menuItemId: 'menu-$id',
  quantity: quantity,
  unitPrice: 20000,
  subtotal: 20000.0 * quantity,
  menuItem: _menu('menu-$id', name),
);

Order _order() {
  final time = DateTime(2026, 7, 25, 10);
  return Order(
    id: 'order-1',
    outletId: 'outlet-1',
    orderNumber: 'KJ-001',
    orderType: OrderType.dineIn,
    status: OrderStatus.confirmed,
    subtotal: 80000,
    discountAmount: 0,
    taxAmount: 0,
    serviceCharge: 0,
    totalAmount: 80000,
    stockDeducted: true,
    createdAt: time,
    updatedAt: time,
    items: [
      _item('item-kebab', 'Kebab Ayam', 2),
      _item('item-kopi', 'Kopi Susu', 2),
    ],
  );
}

void main() {
  testWidgets('kasir dapat mencetak satu item dan jumlah yang dipilih', (
    tester,
  ) async {
    List<OrderItem>? printedItems;
    String? targetPrinterId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () {
                  showModalBottomSheet<KitchenPrintResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SizedBox(
                      height: 600,
                      child: kitchenItemPrintSheetForTesting(
                        order: _order(),
                        printers: const [
                          SavedPrinter(
                            id: 'dapur-a',
                            name: 'Dapur A',
                            dapurEnabled: true,
                            strukEnabled: false,
                          ),
                          SavedPrinter(
                            id: 'dapur-b',
                            name: 'Dapur B',
                            dapurEnabled: true,
                            strukEnabled: false,
                          ),
                        ],
                        printItems: (items, printerId) async {
                          printedItems = items;
                          targetPrinterId = printerId;
                          return const KitchenPrintResult(printed: 1);
                        },
                      ),
                    ),
                  );
                },
                child: const Text('Buka'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Buka'));
    await tester.pumpAndSettle();

    expect(find.text('Kebab Ayam'), findsOneWidget);
    expect(find.text('Kopi Susu'), findsOneWidget);
    final initialButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Cetak 0 Item Terpilih'),
    );
    expect(initialButton.onPressed, isNull);

    await tester.tap(find.byKey(const Key('kitchen-target-printer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dapur B').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tambah jumlah').at(1));
    await tester.pump();
    await tester.tap(find.byTooltip('Tambah jumlah').at(1));
    await tester.pump();
    await tester.tap(find.byTooltip('Tambah jumlah').at(1));
    await tester.pump();

    expect(find.text('2 item dipilih'), findsOneWidget);
    await tester.tap(find.text('Cetak 2 Item Terpilih'));
    await tester.pumpAndSettle();

    expect(printedItems, isNotNull);
    expect(printedItems, hasLength(1));
    expect(printedItems!.single.menuItem?.name, 'Kopi Susu');
    expect(printedItems!.single.quantity, 2);
    expect(targetPrinterId, 'dapur-b');
    expect(find.text('Cetak Tiket Dapur'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pilih Semua memilih seluruh jumlah pesanan', (tester) async {
    List<OrderItem>? printedItems;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 650,
            child: kitchenItemPrintSheetForTesting(
              order: _order(),
              printers: const [
                SavedPrinter(
                  id: 'dapur-a',
                  name: 'Dapur A',
                  dapurEnabled: true,
                  strukEnabled: false,
                ),
              ],
              printItems: (items, printerId) async {
                printedItems = items;
                return const KitchenPrintResult(queued: 1);
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Pilih Semua'));
    await tester.pump();
    expect(find.text('4 item dipilih'), findsOneWidget);

    // Tidak menekan Cetak pada pengujian ini karena helper dipasang sebagai
    // halaman utama, bukan sebagai bottom sheet yang dapat ditutup.
    expect(printedItems, isNull);
    expect(tester.takeException(), isNull);
  });
}

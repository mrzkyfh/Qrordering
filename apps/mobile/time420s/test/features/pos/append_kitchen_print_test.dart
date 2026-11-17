import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/pos/presentation/widgets/cart_panel.dart';
import 'package:time420s/shared/models/menu_item.dart';
import 'package:time420s/shared/models/order.dart';

OrderItem _item(String id, String name) => OrderItem(
  id: id,
  orderId: 'order-1',
  menuItemId: 'menu-$id',
  quantity: 1,
  unitPrice: 10000,
  subtotal: 10000,
  menuItem: MenuItem(
    id: 'menu-$id',
    outletId: 'outlet-1',
    name: name,
    price: 10000,
    isAvailable: true,
    isActive: true,
    isFeatured: false,
    sortOrder: 0,
  ),
);

void main() {
  test(
    'append open-bill hanya meneruskan item hasil RPC ke tiket dapur',
    () async {
      final previousItems = [_item('lama', 'Nasi Lama')];
      final appendedItems = [
        _item('baru-1', 'Kebab Baru'),
        _item('baru-2', 'Es Teh Baru'),
      ];
      List<OrderItem>? printedItems;

      final result = await appendAndPrintNewOrderItems(
        append: () async => appendedItems,
        print: (items) async {
          printedItems = List<OrderItem>.from(items);
        },
      );

      expect(result, same(appendedItems));
      expect(printedItems, isNotNull);
      expect(printedItems!.map((item) => item.id), ['baru-1', 'baru-2']);
      expect(
        printedItems!.map((item) => item.id),
        isNot(contains(previousItems.single.id)),
      );
    },
  );
}

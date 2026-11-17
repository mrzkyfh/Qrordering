import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:time420s/features/pos/data/services/held_order_service.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/features/pos/domain/entities/selected_extra.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/menu_item.dart';

const _menu = MenuItem(
  id: 'menu-1',
  outletId: 'outlet-1',
  categoryId: 'cat-1',
  name: 'Kebab Ayam',
  description: 'Kebab isi ayam',
  price: 20000,
  isAvailable: true,
  isActive: true,
  isFeatured: true,
  allowPriceOverride: true,
  preparationTime: 10,
  tags: ['pedas'],
  variants: [MenuItemVariant(name: 'Besar', priceAddition: 5000)],
  sortOrder: 1,
  categoryName: 'Kebab',
);

const _cart = [
  CartItem(
    id: 'cart-1',
    menuItem: _menu,
    quantity: 2,
    notes: 'Tanpa bawang',
    selectedVariant: MenuItemVariant(name: 'Besar', priceAddition: 5000),
    selectedExtras: [
      SelectedExtra(
        menuExtraId: 'extra-1',
        menuExtraOptionId: 'option-1',
        extraName: 'Saus',
        optionName: 'Pedas',
        price: 2000,
      ),
    ],
    overriddenPrice: 18000,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('held_order_service_test');
    Hive.init(temp.path);
    await Hive.openBox<dynamic>(HeldOrderService.boxName);
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test(
    'pesanan ditahan tersimpan lengkap dan hanya muncul di outlet asal',
    () async {
      await HeldOrderService.save(
        outletId: 'outlet-1',
        items: _cart,
        orderType: OrderType.takeaway,
        tableId: 'table-3',
        tableNumber: '3',
        customerName: 'Budi',
        label: 'Pesanan Budi',
      );

      expect(await HeldOrderService.list('outlet-lain'), isEmpty);
      final held = (await HeldOrderService.list('outlet-1')).single;
      expect(held.label, 'Pesanan Budi');
      expect(held.orderType, OrderType.takeaway);
      expect(held.tableId, 'table-3');
      expect(held.tableNumber, '3');
      expect(held.customerName, 'Budi');
      expect(held.items, hasLength(1));
      expect(held.items.single.quantity, 2);
      expect(held.items.single.notes, 'Tanpa bawang');
      expect(held.items.single.menuItem.name, 'Kebab Ayam');
      expect(held.items.single.menuItem.isFeatured, isTrue);
      expect(held.items.single.menuItem.allowPriceOverride, isTrue);
      expect(held.items.single.overriddenPrice, 18000);
      expect(held.items.single.selectedVariant?.name, 'Besar');
      expect(held.items.single.selectedExtras.single.optionName, 'Pedas');
      expect(held.items.single.unitPrice, 25000);
    },
  );

  test(
    'label kosong memakai pelanggan, kemudian pesanan dapat dihapus',
    () async {
      await HeldOrderService.save(
        outletId: 'outlet-1',
        items: _cart,
        orderType: OrderType.dineIn,
        customerName: '  Sari  ',
        label: '   ',
      );

      final held = (await HeldOrderService.list('outlet-1')).single;
      expect(held.label, 'Sari');

      await HeldOrderService.remove(held.id);
      expect(await HeldOrderService.list('outlet-1'), isEmpty);
    },
  );

  test('baris lokal rusak tidak menghilangkan pesanan valid lain', () async {
    final box = Hive.box<dynamic>(HeldOrderService.boxName);
    await box.put('rusak', {
      'id': 'rusak',
      'outlet_id': 'outlet-1',
      'created_at': 'bukan-tanggal',
    });
    await HeldOrderService.save(
      outletId: 'outlet-1',
      items: _cart,
      orderType: OrderType.dineIn,
      label: 'Valid',
    );

    final held = await HeldOrderService.list('outlet-1');
    expect(held, hasLength(1));
    expect(held.single.label, 'Valid');
  });
}

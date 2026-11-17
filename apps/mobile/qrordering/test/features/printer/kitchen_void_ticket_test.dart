import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/order.dart';
import 'package:qrordering/shared/services/kitchen_ticket_builder.dart';

bool _containsSequence(List<int> bytes, List<int> sequence) {
  for (var i = 0; i <= bytes.length - sequence.length; i++) {
    var matches = true;
    for (var j = 0; j < sequence.length; j++) {
      if (bytes[i + j] != sequence[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

bool _endsWithSequence(List<int> bytes, List<int> sequence) {
  if (bytes.length < sequence.length) return false;
  final offset = bytes.length - sequence.length;
  for (var i = 0; i < sequence.length; i++) {
    if (bytes[offset + i] != sequence[i]) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('id_ID'));

  test('tiket dapur mengikuti susunan dan memakai Font A yang terbaca', () async {
    final createdAt = DateTime(2026, 7, 24, 12, 6);
    final item = OrderItem(
      id: 'item-1',
      orderId: 'order-1',
      menuItemId: 'menu-1',
      quantity: 1,
      unitPrice: 25000,
      subtotal: 25000,
      notes: 'Less ice',
      menuItem: const MenuItem(
        id: 'menu-1',
        outletId: 'outlet-1',
        name: 'Cheesy Double',
        price: 25000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      ),
      options: const [
        OrderItemOption(
          extraName: 'Extra Meat',
          optionName: 'Medium',
          price: 13000,
        ),
      ],
    );
    final order = Order(
      id: 'order-1',
      outletId: 'outlet-1',
      orderNumber: 'CS/46/260724/0003',
      orderType: OrderType.selfOrder,
      status: OrderStatus.confirmed,
      customerName: 'Dino M',
      tableNumber: 'A1',
      notes:
          'Jenis layanan: Makan di Tempat (Meja A1)\nAntar semua menu bersamaan',
      subtotal: 25000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 25000,
      stockDeducted: true,
      createdAt: createdAt,
      updatedAt: createdAt,
      items: [item],
    );

    final bytes = await KitchenTicketBuilder().build(
      order: order,
      stationName: 'Kebab',
      items: [item],
      printedAt: createdAt,
      printedBy: 'Dino M',
    );
    final output = String.fromCharCodes(bytes);

    expect(output, contains('DAPUR - KEBAB'));
    expect(output, contains('No Nota     : CS/46/260724/0003'));
    expect(output, contains('Waktu       : 24 Jul 26 12:06'));
    expect(output, contains('Order       : Pesanan QR'));
    expect(output, contains('Customer    : Dino M'));
    expect(output, contains('MAKAN DI TEMPAT - MEJA A1'));
    expect(output, isNot(contains('Jenis Order')));
    expect(output, isNot(contains('Nama Order')));
    expect(output, isNot(contains('Nomor Meja')));
    expect(output, contains('1 CHEESY DOUBLE'));
    expect(output, contains('+ 1 MEDIUM'));
    expect(output, contains('> Less ice'));
    expect(output, contains('CATATAN ORDER'));
    expect(output, contains('ANTAR SEMUA MENU BERSAMAAN'));
    expect(
      output.indexOf('CATATAN ORDER'),
      lessThan(output.indexOf('1 CHEESY')),
    );
    expect(output, contains('dicetak: Dino M'));
    expect(output, isNot(contains('Rp')));
    // ESC M 0 = Font A (lebih besar); ESC M 1 = Font B yang terlalu kecil.
    expect(_containsSequence(bytes, [27, 77, 0]), true);
    expect(_containsSequence(bytes, [27, 77, 1]), false);
    var threeLineFeeds = 0;
    for (var i = 0; i < bytes.length - 2; i++) {
      if (bytes[i] == 27 && bytes[i + 1] == 100 && bytes[i + 2] == 3) {
        threeLineFeeds++;
      }
    }
    expect(threeLineFeeds, 1);
    // Final feed hanya dimiliki helper global: tiga baris sebelum full-cut.
    expect(_endsWithSequence(bytes, [27, 100, 3, 29, 86, 48]), true);
    expect(_containsSequence(bytes, [10, 10, 10, 10, 10, 29, 86, 48]), false);
  });

  test('tiket Void dapur mengikuti susunan contoh operasional', () async {
    final printedAt = DateTime(2026, 7, 24, 12, 6);
    final item = OrderItem(
      id: 'item-1',
      orderId: 'order-1',
      menuItemId: 'menu-1',
      quantity: 1,
      unitPrice: 25000,
      subtotal: 25000,
      menuItem: const MenuItem(
        id: 'menu-1',
        outletId: 'outlet-1',
        name: 'Cheesy Double',
        price: 25000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      ),
    );
    final order = Order(
      id: 'order-1',
      outletId: 'outlet-1',
      orderNumber: 'CS/46/260724/0003',
      orderType: OrderType.dineIn,
      status: OrderStatus.void_,
      customerName: 'Dino M',
      subtotal: 25000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 25000,
      stockDeducted: false,
      createdAt: printedAt,
      updatedAt: printedAt,
      items: [item],
    );

    final bytes = await KitchenTicketBuilder().buildVoid(
      order: order,
      stationName: 'Kebab',
      items: [item],
      printedAt: printedAt,
      printedBy: 'Dino M',
    );
    final output = String.fromCharCodes(bytes);

    expect(output, contains('VOID Dapur - KEBAB'));
    expect(output, contains('No Nota  : CS/46/260724/0003'));
    expect(output, contains('Waktu    : 24 Jul 26 12:06'));
    expect(output, contains('Order    : Dino M'));
    expect(output, contains('1 CHEESY DOUBLE'));
    expect(output, contains('dicetak: Dino M'));
    expect(_containsSequence(bytes, [27, 77, 0]), true);
    expect(_containsSequence(bytes, [27, 77, 1]), false);
    expect(_endsWithSequence(bytes, [27, 100, 3, 29, 86, 48]), true);
  });

  test('nama stasiun yang sudah diawali Dapur tidak ditulis dua kali', () {
    expect(kitchenTitle('Kebab'), 'DAPUR - KEBAB');
    expect(kitchenTitle('Dapur - Kebab'), 'DAPUR - KEBAB');
    expect(voidKitchenTitle('Dapur - Kebab'), 'VOID Dapur - KEBAB');
    expect(voidKitchenTitle('Dapur'), 'VOID Dapur');
  });

  test('tiket dapur QR bawa pulang tetap mencetak nomor meja asal', () async {
    final now = DateTime(2026, 10, 1, 12);
    final item = OrderItem(
      id: 'item-pickup',
      orderId: 'order-pickup',
      menuItemId: 'menu-1',
      quantity: 1,
      unitPrice: 10000,
      subtotal: 10000,
      menuItem: const MenuItem(
        id: 'menu-1',
        outletId: 'outlet-1',
        name: 'Es Teh',
        price: 10000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      ),
    );
    final order = Order(
      id: 'order-pickup',
      outletId: 'outlet-1',
      tableId: 'table-a1',
      tableNumber: 'A1',
      orderNumber: 'QR-001',
      orderType: OrderType.selfOrder,
      status: OrderStatus.draft,
      customerName: 'Siti',
      notes: 'Jenis layanan: Bawa Pulang',
      subtotal: 10000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 10000,
      stockDeducted: false,
      createdAt: now,
      updatedAt: now,
      items: [item],
    );

    final bytes = await KitchenTicketBuilder().build(
      order: order,
      stationName: 'Bar',
      items: [item],
      printedAt: now,
    );
    final output = String.fromCharCodes(bytes);

    expect(output, contains('BAWA PULANG - MEJA A1'));
    expect(output, isNot(contains('Nomor Meja')));
  });
}

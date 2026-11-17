import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/pos/domain/catalog_reconciliation.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/features/pos/domain/entities/selected_extra.dart';
import 'package:time420s/shared/models/menu_extra.dart';
import 'package:time420s/shared/models/menu_item.dart';

MenuItem item({
  double price = 10000,
  bool active = true,
  bool available = true,
  List<MenuItemVariant>? variants,
  List<MenuExtra>? extras,
}) => MenuItem(
  id: 'menu-1',
  outletId: 'outlet-1',
  name: 'Kopi',
  price: price,
  isAvailable: available,
  isActive: active,
  isFeatured: false,
  variants: variants,
  extras: extras,
  sortOrder: 0,
);

CartItem cart(MenuItem menu, {List<SelectedExtra> extras = const []}) =>
    CartItem(id: 'cart-1', menuItem: menu, quantity: 2, selectedExtras: extras);

void main() {
  test('katalog sama dapat langsung ditransaksikan', () {
    final old = item();
    final result = reconcileCartCatalog([cart(old)], [old]);
    expect(result.changed, isFalse);
    expect(result.blocking, isFalse);
    expect(result.cart.single.unitPrice, 10000);
  });

  test('harga berubah memperbarui keranjang dan meminta konfirmasi ulang', () {
    final result = reconcileCartCatalog([cart(item())], [item(price: 12000)]);
    expect(result.changed, isTrue);
    expect(result.blocking, isFalse);
    expect(result.cart.single.unitPrice, 12000);
    expect(result.cart.single.subtotal, 24000);
    expect(result.messages, contains('Harga Kopi diperbarui'));
  });

  test(
    'produk dihapus tidak dibuang dari keranjang tetapi pembayaran diblok',
    () {
      final original = cart(item());
      final result = reconcileCartCatalog([original], const []);
      expect(result.blocking, isTrue);
      expect(result.cart.single, original);
      expect(result.messages.single, contains('dihapus/nonaktif'));
    },
  );

  test('produk habis memblok transaksi', () {
    final result = reconcileCartCatalog(
      [cart(item())],
      [item(available: false)],
    );
    expect(result.blocking, isTrue);
    expect(result.messages.single, contains('tidak tersedia'));
  });

  test('harga extra terbaru menggantikan snapshot lama', () {
    const selected = SelectedExtra(
      menuExtraId: 'extra-1',
      menuExtraOptionId: 'option-1',
      extraName: 'Susu',
      optionName: 'Oat',
      price: 2000,
    );
    final fresh = item(
      extras: const [
        MenuExtra(
          id: 'extra-1',
          outletId: 'outlet-1',
          name: 'Susu',
          type: 'optional',
          selectionType: 'single',
          isActive: true,
          sortOrder: 0,
          options: [
            MenuExtraOption(
              id: 'option-1',
              extraId: 'extra-1',
              name: 'Oat',
              price: 3000,
              sortOrder: 0,
            ),
          ],
        ),
      ],
    );
    final result = reconcileCartCatalog(
      [
        cart(item(), extras: const [selected]),
      ],
      [fresh],
    );
    expect(result.blocking, isFalse);
    expect(result.changed, isTrue);
    expect(result.cart.single.unitPrice, 13000);
  });

  test('extra wajib baru memblok sampai kasir memilih ulang', () {
    final fresh = item(
      extras: const [
        MenuExtra(
          id: 'extra-required',
          outletId: 'outlet-1',
          name: 'Ukuran',
          type: 'required',
          selectionType: 'single',
          isActive: true,
          sortOrder: 0,
          options: [],
        ),
      ],
    );
    final result = reconcileCartCatalog([cart(item())], [fresh]);
    expect(result.blocking, isTrue);
    expect(result.messages.single, contains('memerlukan pilihan Ukuran'));
  });
}

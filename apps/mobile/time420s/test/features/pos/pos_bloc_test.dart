import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/domain/catalog_reconciliation.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/features/pos/domain/entities/selected_extra.dart';
import 'package:time420s/features/pos/presentation/bloc/pos_bloc.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/menu_category.dart';
import 'package:time420s/shared/models/menu_item.dart';
import 'package:time420s/shared/models/menu_extra.dart';

class MockPosDatasource extends Mock implements PosDatasource {}

MenuItem _makeItem({
  String id = 'item-1',
  String name = 'Nasi Goreng',
  double price = 25000,
  String? categoryId,
  bool isFeatured = false,
  bool allowPriceOverride = false,
  int sortOrder = 0,
  List<MenuItemVariant>? variants,
  List<MenuExtra>? extras,
}) => MenuItem(
  id: id,
  outletId: 'outlet-1',
  name: name,
  price: price,
  categoryId: categoryId,
  isAvailable: true,
  isActive: true,
  isFeatured: isFeatured,
  allowPriceOverride: allowPriceOverride,
  variants: variants,
  extras: extras,
  sortOrder: sortOrder,
);

MenuCategory _makeCategory({
  String id = 'cat-1',
  String name = 'Makanan',
  int sortOrder = 0,
}) => MenuCategory(
  id: id,
  outletId: 'outlet-1',
  name: name,
  sortOrder: sortOrder,
  isActive: true,
);

CartItem _makeCartItem(MenuItem item, {int quantity = 1}) =>
    CartItem(id: 'test-cart-id', menuItem: item, quantity: quantity);

void main() {
  late MockPosDatasource datasource;

  setUpAll(() {
    registerFallbackValue(OrderType.dineIn);
  });

  setUp(() {
    datasource = MockPosDatasource();
    // fetchOutletSettings dipanggil tiap load menu (pajak/service charge dll).
    // Default stub agar test load-menu tak gagal dengan null.
    when(
      () => datasource.fetchOutletSettings(any()),
    ).thenAnswer((_) async => <String, dynamic>{});
  });

  // ─── Initial State ────────────────────────────────────────────────────────

  group('Initial State', () {
    test('state awal: cart kosong, subtotal 0, orderType dineIn', () {
      final bloc = PosBloc(datasource: datasource);
      expect(bloc.state.cart, isEmpty);
      expect(bloc.state.subtotal, 0);
      expect(bloc.state.total, 0);
      expect(bloc.state.itemCount, 0);
      expect(bloc.state.orderType, OrderType.dineIn);
      bloc.close();
    });

    test(
      'kategori mengikuti sort_order web dan nama memecahkan urutan sama',
      () {
        final state = PosState(
          categories: [
            _makeCategory(id: 'c3', name: 'Snack', sortOrder: 3),
            _makeCategory(id: 'c2b', name: 'Burger', sortOrder: 2),
            _makeCategory(id: 'c1', name: 'Kebab', sortOrder: 1),
            _makeCategory(id: 'c2a', name: 'Americano', sortOrder: 2),
          ],
        );

        expect(state.sortedCategories.map((category) => category.name), [
          'Kebab',
          'Americano',
          'Burger',
          'Snack',
        ]);
      },
    );
  });

  // ─── Load Menu ────────────────────────────────────────────────────────────

  group('PosMenuLoadRequested', () {
    blocTest<PosBloc, PosState>(
      'berhasil: emit loading → loaded dengan kategori dan item',
      build: () {
        when(
          () => datasource.fetchCategories('outlet-1'),
        ).thenAnswer((_) async => [_makeCategory()]);
        when(
          () => datasource.fetchMenuItems('outlet-1'),
        ).thenAnswer((_) async => [_makeItem()]);
        return PosBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(PosMenuLoadRequested('outlet-1')),
      expect: () => [
        isA<PosState>().having((s) => s.menuLoading, 'loading', true),
        isA<PosState>()
            .having((s) => s.menuLoading, 'loading', false)
            .having((s) => s.categories.length, 'categories', 1)
            .having((s) => s.menuItems.length, 'items', 1),
      ],
    );

    blocTest<PosBloc, PosState>(
      'gagal: emit loading → error',
      build: () {
        when(
          () => datasource.fetchCategories(any()),
        ).thenThrow(Exception('network error'));
        when(
          () => datasource.fetchMenuItems(any()),
        ).thenThrow(Exception('network error'));
        return PosBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(PosMenuLoadRequested('outlet-1')),
      expect: () => [
        isA<PosState>().having((s) => s.menuLoading, 'loading', true),
        isA<PosState>()
            .having((s) => s.menuLoading, 'loading', false)
            .having((s) => s.menuError, 'error', isNotNull),
      ],
    );

    // Regresi BUG-004: outletId kosong → pesan jelas, BUKAN crash uuid,
    // dan tidak memanggil datasource.
    blocTest<PosBloc, PosState>(
      'outletId kosong: emit menuError tanpa loading & tanpa query',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(PosMenuLoadRequested('')),
      expect: () => [
        isA<PosState>()
            .having((s) => s.menuLoading, 'loading', false)
            .having((s) => s.menuError, 'error', isNotNull),
      ],
      verify: (_) {
        verifyNever(() => datasource.fetchCategories(any()));
        verifyNever(() => datasource.fetchMenuItems(any()));
      },
    );

    // Regresi: menuError dari load gagal harus ter-CLEAR saat reload sukses.
    blocTest<PosBloc, PosState>(
      'reload sukses meng-clear menuError sebelumnya',
      build: () {
        when(
          () => datasource.fetchCategories('outlet-1'),
        ).thenAnswer((_) async => [_makeCategory()]);
        when(
          () => datasource.fetchMenuItems('outlet-1'),
        ).thenAnswer((_) async => [_makeItem()]);
        return PosBloc(datasource: datasource);
      },
      seed: () => const PosState(menuError: 'error lama'),
      act: (bloc) => bloc.add(PosMenuLoadRequested('outlet-1')),
      expect: () => [
        isA<PosState>().having((s) => s.menuLoading, 'loading', true),
        isA<PosState>()
            .having((s) => s.menuLoading, 'loading', false)
            .having((s) => s.menuError, 'error', isNull)
            .having((s) => s.menuItems.length, 'items', 1),
      ],
    );
  });

  group('PosCatalogReconciled', () {
    blocTest<PosBloc, PosState>(
      'memperbarui harga keranjang tanpa menghapus menu lain dan melepas diskon lama',
      build: () => PosBloc(datasource: datasource),
      seed: () {
        final stale = _makeItem(price: 10000);
        return PosState(
          menuItems: [
            stale,
            _makeItem(id: 'item-2', name: 'Teh'),
          ],
          cart: [_makeCartItem(stale)],
          promoId: 'promo-lama',
          promoCode: 'HEMAT',
          discountAmount: 1000,
          redeemedPoints: 10,
          loyaltyDiscount: 500,
        );
      },
      act: (bloc) {
        final fresh = _makeItem(price: 12000);
        bloc.add(
          PosCatalogReconciled(
            CatalogReconciliation(
              cart: [_makeCartItem(fresh)],
              catalog: [fresh],
              messages: const ['Harga Nasi Goreng diperbarui'],
              blocking: false,
              changed: true,
            ),
          ),
        );
      },
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart.single.unitPrice, 'harga', 12000)
            .having((s) => s.menuItems.length, 'menu tetap lengkap', 2)
            .having((s) => s.discountAmount, 'promo dilepas', 0)
            .having((s) => s.redeemedPoints, 'redeem dilepas', 0),
      ],
    );
  });

  // ─── Category Filter ──────────────────────────────────────────────────────

  group('PosCategorySelected', () {
    blocTest<PosBloc, PosState>(
      'pilih kategori menyimpan selectedCategoryId',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(PosCategorySelected('cat-1')),
      expect: () => [
        isA<PosState>().having(
          (s) => s.selectedCategoryId,
          'categoryId',
          'cat-1',
        ),
      ],
    );

    blocTest<PosBloc, PosState>(
      'null categoryId menghapus filter (tampilkan semua)',
      build: () => PosBloc(datasource: datasource),
      seed: () => const PosState(selectedCategoryId: 'cat-1'),
      act: (bloc) => bloc.add(PosCategorySelected(null)),
      expect: () => [
        isA<PosState>().having(
          (s) => s.selectedCategoryId,
          'categoryId',
          isNull,
        ),
      ],
    );
  });

  group('Menu unggulan', () {
    test('menu unggulan selalu muncul lebih dulu setelah filter kategori', () {
      final state = PosState(
        selectedCategoryId: 'cat-1',
        menuItems: [
          _makeItem(
            id: 'regular',
            name: 'Ayam Biasa',
            categoryId: 'cat-1',
            sortOrder: 0,
          ),
          _makeItem(
            id: 'featured-2',
            name: 'Unggulan Kedua',
            categoryId: 'cat-1',
            isFeatured: true,
            sortOrder: 2,
          ),
          _makeItem(
            id: 'featured-1',
            name: 'Unggulan Pertama',
            categoryId: 'cat-1',
            isFeatured: true,
            sortOrder: 1,
          ),
          _makeItem(
            id: 'other-category',
            name: 'Kategori Lain',
            categoryId: 'cat-2',
            isFeatured: true,
          ),
        ],
      );

      expect(state.filteredMenu.map((item) => item.id), [
        'featured-1',
        'featured-2',
        'regular',
      ]);
    });

    test('perubahan isFeatured dianggap perubahan model', () {
      final regular = _makeItem(id: 'same');
      final featured = _makeItem(id: 'same', isFeatured: true);

      expect(regular, isNot(equals(featured)));
    });

    test('perubahan aturan extra dianggap perubahan model menu', () {
      const optional = MenuExtra(
        id: 'extra-1',
        outletId: 'outlet-1',
        name: 'HOT/ICE',
        type: 'optional',
        selectionType: 'single',
        isActive: true,
        sortOrder: 0,
        options: [],
      );
      const required = MenuExtra(
        id: 'extra-1',
        outletId: 'outlet-1',
        name: 'HOT/ICE',
        type: 'required',
        selectionType: 'single',
        isActive: true,
        sortOrder: 0,
        options: [],
      );

      expect(
        _makeItem(id: 'same', extras: const [optional]),
        isNot(equals(_makeItem(id: 'same', extras: const [required]))),
      );
    });
  });

  // ─── Cart: Add Item ───────────────────────────────────────────────────────

  group('PosItemAdded', () {
    const requiredExtra = MenuExtra(
      id: 'extra-temperature',
      outletId: 'outlet-1',
      name: 'HOT/ICE',
      type: 'required',
      selectionType: 'single',
      isActive: true,
      sortOrder: 0,
      options: [
        MenuExtraOption(
          id: 'option-hot',
          extraId: 'extra-temperature',
          name: 'HOT',
          price: 0,
          sortOrder: 0,
        ),
      ],
    );

    blocTest<PosBloc, PosState>(
      'item dengan pilihan wajib tidak dapat ditambah tanpa pilihan',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosItemAdded(
          _makeItem(name: 'Vanilla Latte', extras: const [requiredExtra]),
        ),
      ),
      expect: () => const <PosState>[],
      verify: (bloc) => expect(bloc.state.cart, isEmpty),
    );

    blocTest<PosBloc, PosState>(
      'item dengan pilihan wajib dapat ditambah setelah opsi dipilih',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosItemAdded(
          _makeItem(name: 'Vanilla Latte', extras: const [requiredExtra]),
          selectedExtras: const [
            SelectedExtra(
              menuExtraId: 'extra-temperature',
              menuExtraOptionId: 'option-hot',
              extraName: 'HOT/ICE',
              optionName: 'HOT',
              price: 0,
            ),
          ],
        ),
      ),
      expect: () => [
        isA<PosState>()
            .having((state) => state.cart.length, 'cart.length', 1)
            .having(
              (state) => state.cart.single.selectedExtras.single.optionName,
              'pilihan',
              'HOT',
            ),
      ],
    );

    blocTest<PosBloc, PosState>(
      'tambah item baru menghasilkan 1 cart entry',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(PosItemAdded(_makeItem())),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart.length, 'cart.length', 1)
            .having((s) => s.itemCount, 'itemCount', 1)
            .having((s) => s.subtotal, 'subtotal', 25000.0),
      ],
    );

    blocTest<PosBloc, PosState>(
      'tambah item yang sama dua kali: qty=2, cart.length=1',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) {
        bloc.add(PosItemAdded(_makeItem()));
        bloc.add(PosItemAdded(_makeItem()));
      },
      expect: () => [
        isA<PosState>().having((s) => s.cart.length, 'cart', 1),
        isA<PosState>()
            .having((s) => s.cart.length, 'cart', 1)
            .having((s) => s.itemCount, 'qty', 2)
            .having((s) => s.subtotal, 'subtotal', 50000.0),
      ],
    );

    blocTest<PosBloc, PosState>(
      'tambah dua item berbeda: cart.length=2',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) {
        bloc.add(PosItemAdded(_makeItem(id: 'item-1', price: 25000)));
        bloc.add(PosItemAdded(_makeItem(id: 'item-2', price: 15000)));
      },
      expect: () => [
        isA<PosState>().having((s) => s.cart.length, 'cart', 1),
        isA<PosState>()
            .having((s) => s.cart.length, 'cart', 2)
            .having((s) => s.subtotal, 'subtotal', 40000.0),
      ],
    );

    blocTest<PosBloc, PosState>(
      'harga kasir dipakai hanya saat produk mengizinkan perubahan harga',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosItemAdded(
          _makeItem(price: 25000, allowPriceOverride: true),
          overriddenPrice: 18000,
        ),
      ),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart.single.overriddenPrice, 'harga kasir', 18000)
            .having((s) => s.subtotal, 'subtotal', 18000),
      ],
    );

    blocTest<PosBloc, PosState>(
      'harga kasir ditolak bila toggle produk tidak aktif',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosItemAdded(_makeItem(price: 25000), overriddenPrice: 18000),
      ),
      expect: () => const <PosState>[],
      verify: (bloc) => expect(bloc.state.cart, isEmpty),
    );
  });

  // ─── Cart: Remove Item ────────────────────────────────────────────────────

  group('PosItemRemoved', () {
    blocTest<PosBloc, PosState>(
      'hapus item dari cart mengosongkan cart',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) async {
        bloc.add(PosItemAdded(_makeItem()));
        await Future.delayed(Duration.zero);
        bloc.add(PosItemRemoved(bloc.state.cart.first.id));
      },
      expect: () => [
        isA<PosState>().having((s) => s.cart.length, 'setelah add', 1),
        isA<PosState>().having((s) => s.cart.length, 'setelah remove', 0),
      ],
    );
  });

  // ─── Cart: Change Quantity ────────────────────────────────────────────────

  group('PosQuantityChanged', () {
    blocTest<PosBloc, PosState>(
      '+1 menaikkan qty dan subtotal',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) async {
        bloc.add(PosItemAdded(_makeItem()));
        await Future.delayed(Duration.zero);
        bloc.add(PosQuantityChanged(bloc.state.cart.first.id, 1));
      },
      expect: () => [
        isA<PosState>().having((s) => s.itemCount, 'qty', 1),
        isA<PosState>()
            .having((s) => s.itemCount, 'qty setelah +1', 2)
            .having((s) => s.subtotal, 'subtotal', 50000.0),
      ],
    );

    blocTest<PosBloc, PosState>(
      '-1 pada qty=1 otomatis hapus item (qty tidak boleh ≤ 0)',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) async {
        bloc.add(PosItemAdded(_makeItem()));
        await Future.delayed(Duration.zero);
        bloc.add(PosQuantityChanged(bloc.state.cart.first.id, -1));
      },
      expect: () => [
        isA<PosState>().having((s) => s.cart.length, 'setelah add', 1),
        isA<PosState>().having((s) => s.cart.length, 'setelah -1', 0),
      ],
    );
  });

  // ─── Cart: Notes ──────────────────────────────────────────────────────────

  group('PosNotesChanged', () {
    blocTest<PosBloc, PosState>(
      'simpan catatan pada cart item',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) async {
        bloc.add(PosItemAdded(_makeItem()));
        await Future.delayed(Duration.zero);
        bloc.add(PosNotesChanged(bloc.state.cart.first.id, 'pedas extra'));
      },
      expect: () => [
        isA<PosState>().having((s) => s.cart.first.notes, 'notes awal', isNull),
        isA<PosState>().having(
          (s) => s.cart.first.notes,
          'notes',
          'pedas extra',
        ),
      ],
    );
  });

  // ─── Order Type ───────────────────────────────────────────────────────────

  group('PosOrderTypeChanged', () {
    blocTest<PosBloc, PosState>(
      'ganti ke takeaway menghapus tableId',
      build: () => PosBloc(datasource: datasource),
      seed: () => const PosState(
        orderType: OrderType.dineIn,
        tableId: 'table-1',
        tableNumber: '5',
      ),
      act: (bloc) => bloc.add(PosOrderTypeChanged(OrderType.takeaway)),
      expect: () => [
        isA<PosState>()
            .having((s) => s.orderType, 'type', OrderType.takeaway)
            .having((s) => s.tableId, 'tableId', isNull)
            .having((s) => s.tableNumber, 'tableNumber', isNull),
      ],
    );

    blocTest<PosBloc, PosState>(
      'ganti ke dine_in tidak otomatis assign meja',
      build: () => PosBloc(datasource: datasource),
      seed: () => const PosState(orderType: OrderType.takeaway),
      act: (bloc) => bloc.add(PosOrderTypeChanged(OrderType.dineIn)),
      expect: () => [
        isA<PosState>()
            .having((s) => s.orderType, 'type', OrderType.dineIn)
            .having((s) => s.tableId, 'tableId', isNull),
      ],
    );

    blocTest<PosBloc, PosState>(
      'tipe order induk tidak dapat diubah selama mode tambah pesanan',
      build: () => PosBloc(datasource: datasource),
      seed: () => const PosState(
        orderType: OrderType.selfOrder,
        tableId: 'table-17',
        tableNumber: '17',
        appendOrderId: 'order-083',
      ),
      act: (bloc) => bloc.add(PosOrderTypeChanged(OrderType.takeaway)),
      expect: () => <PosState>[],
      verify: (bloc) {
        expect(bloc.state.orderType, OrderType.selfOrder);
        expect(bloc.state.tableNumber, '17');
      },
    );
  });

  // ─── Table Selection ──────────────────────────────────────────────────────

  group('PosTableSelected', () {
    blocTest<PosBloc, PosState>(
      'pilih meja menyimpan tableId dan tableNumber',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(PosTableSelected('table-5', '5')),
      expect: () => [
        isA<PosState>()
            .having((s) => s.tableId, 'tableId', 'table-5')
            .having((s) => s.tableNumber, 'tableNumber', '5'),
      ],
    );

    test(
      'PosTableSelected(null, null) tidak mengubah state (gunakan PosOrderTypeChanged untuk clear meja)',
      () {
        // copyWith menggunakan ?? sehingga null tidak override nilai lama.
        // Untuk clear meja, gunakan PosOrderTypeChanged ke takeaway (clearTable: true).
        final state = const PosState(tableId: 'table-5', tableNumber: '5');
        final next = state.copyWith(tableId: null, tableNumber: null);
        expect(next.tableId, 'table-5');
        expect(next.tableNumber, '5');
      },
    );
  });

  // ─── Clear Cart ───────────────────────────────────────────────────────────

  group('PosCartCleared', () {
    blocTest<PosBloc, PosState>(
      'clear cart mengosongkan item, diskon, dan seluruh mode edit',
      build: () => PosBloc(datasource: datasource),
      seed: () => PosState(
        cart: [_makeCartItem(_makeItem())],
        orderType: OrderType.selfOrder,
        tableId: 'table-17',
        tableNumber: '17',
        discountAmount: 5000,
        appendOrderId: 'order-083',
        appendOrderNumber: '083',
        editingOrderId: 'draft-1',
        editingOrderNumber: 'D-001',
        replaceOrderId: 'online-1',
        replaceOrderNumber: 'O-001',
      ),
      act: (bloc) => bloc.add(PosCartCleared()),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart, 'cart', isEmpty)
            .having((s) => s.discountAmount, 'discount', 0.0)
            .having((s) => s.orderType, 'type', OrderType.dineIn)
            .having((s) => s.tableId, 'table id', isNull)
            .having((s) => s.tableNumber, 'table number', isNull)
            .having((s) => s.appendOrderId, 'append order', isNull)
            .having((s) => s.appendOrderNumber, 'append number', isNull)
            .having((s) => s.editingOrderId, 'editing order', isNull)
            .having((s) => s.editingOrderNumber, 'editing number', isNull)
            .having((s) => s.replaceOrderId, 'replace order', isNull)
            .having((s) => s.replaceOrderNumber, 'replace number', isNull),
      ],
    );
  });

  group('PosAppendCancelled', () {
    blocTest<PosBloc, PosState>(
      'keluar mode tambah membersihkan order induk, meja, dan item',
      build: () => PosBloc(datasource: datasource),
      seed: () => PosState(
        cart: [_makeCartItem(_makeItem())],
        orderType: OrderType.selfOrder,
        tableId: 'table-17',
        tableNumber: '17',
        customerName: 'Zaskia',
        appendOrderId: 'order-083',
        appendOrderNumber: '083',
      ),
      act: (bloc) => bloc.add(PosAppendCancelled()),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart, 'cart', isEmpty)
            .having((s) => s.appendOrderId, 'append order', isNull)
            .having((s) => s.appendOrderNumber, 'append number', isNull)
            .having((s) => s.tableId, 'table id', isNull)
            .having((s) => s.tableNumber, 'table number', isNull)
            .having((s) => s.customerName, 'customer', isNull)
            .having((s) => s.orderType, 'safe new type', OrderType.takeaway),
      ],
    );
  });

  group('PosCartLoaded edit pesanan online', () {
    blocTest<PosBloc, PosState>(
      'memuat item tanpa mengganti identitas order online',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosCartLoaded(
          [_makeCartItem(_makeItem())],
          orderType: OrderType.selfOrder,
          customerName: 'Pelanggan Online',
          replaceOrderId: 'online-1',
          replaceOrderNumber: 'ON-001',
        ),
      ),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart.length, 'cart', 1)
            .having((s) => s.orderType, 'type', OrderType.selfOrder)
            .having((s) => s.customerName, 'customer', 'Pelanggan Online')
            .having((s) => s.replaceOrderId, 'replace order', 'online-1')
            .having((s) => s.replaceOrderNumber, 'replace number', 'ON-001')
            .having((s) => s.editingOrderId, 'draft edit', isNull),
      ],
    );
  });

  group('PosCartLoaded edit draft', () {
    blocTest<PosBloc, PosState>(
      'memuat draft tanpa kehilangan identitas order yang akan digantikan',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(
        PosCartLoaded(
          [_makeCartItem(_makeItem())],
          editingOrderId: 'draft-1',
          editingOrderNumber: 'D-001',
        ),
      ),
      expect: () => [
        isA<PosState>()
            .having((s) => s.cart.length, 'cart', 1)
            .having((s) => s.editingOrderId, 'editing order', 'draft-1')
            .having((s) => s.editingOrderNumber, 'editing number', 'D-001'),
      ],
    );
  });

  // ─── Revalidasi diskon saat keranjang berubah ─────────────────────────────
  // Regresi: diskon promo dihitung dari subtotal SAAT kode diterapkan; tanpa
  // revalidasi, mengubah keranjang membawa diskon basi (bisa melebihi ketentuan
  // promo, mis. subtotal turun di bawah minimum pembelian).

  group('Revalidasi promo saat cart berubah', () {
    PosState seedWithPromo() => PosState(
      loadedOutletId: 'outlet-1',
      cart: [_makeCartItem(_makeItem(price: 50000), quantity: 2)],
      promoCode: 'HEMAT10',
      promoId: 'promo-1',
      discountAmount: 10000,
    );

    blocTest<PosBloc, PosState>(
      'qty berubah → validatePromo dipanggil ulang dengan subtotal baru',
      build: () {
        when(
          () => datasource.validatePromo(
            code: 'HEMAT10',
            outletId: 'outlet-1',
            subtotal: any(named: 'subtotal'),
          ),
        ).thenAnswer(
          (_) async => {'promo_id': 'promo-1', 'discount_amount': 15000},
        );
        return PosBloc(datasource: datasource);
      },
      seed: seedWithPromo,
      act: (bloc) => bloc.add(PosQuantityChanged(bloc.state.cart.first.id, 1)),
      expect: () => [
        isA<PosState>().having((s) => s.itemCount, 'qty', 3),
        isA<PosState>().having(
          (s) => s.discountAmount,
          'diskon dihitung ulang',
          15000.0,
        ),
      ],
      verify: (_) {
        verify(
          () => datasource.validatePromo(
            code: 'HEMAT10',
            outletId: 'outlet-1',
            subtotal: 150000,
          ),
        ).called(1);
      },
    );

    blocTest<PosBloc, PosState>(
      'promo tak lagi valid setelah cart berubah → diskon dilepas + promoError',
      build: () {
        when(
          () => datasource.validatePromo(
            code: 'HEMAT10',
            outletId: 'outlet-1',
            subtotal: any(named: 'subtotal'),
          ),
        ).thenThrow(Exception('Minimal pembelian Rp 100.000'));
        return PosBloc(datasource: datasource);
      },
      seed: seedWithPromo,
      act: (bloc) => bloc.add(PosQuantityChanged(bloc.state.cart.first.id, -1)),
      expect: () => [
        isA<PosState>().having((s) => s.itemCount, 'qty', 1),
        isA<PosState>()
            .having((s) => s.promoCode, 'promo dilepas', isNull)
            .having((s) => s.discountAmount, 'diskon', 0.0)
            .having((s) => s.promoError, 'error', isNotNull),
      ],
    );

    blocTest<PosBloc, PosState>(
      'cart jadi kosong → promo dilepas tanpa memanggil server',
      build: () => PosBloc(datasource: datasource),
      seed: () => PosState(
        loadedOutletId: 'outlet-1',
        cart: [_makeCartItem(_makeItem(price: 50000))],
        promoCode: 'HEMAT10',
        promoId: 'promo-1',
        discountAmount: 10000,
      ),
      act: (bloc) => bloc.add(PosItemRemoved(bloc.state.cart.first.id)),
      expect: () => [
        isA<PosState>().having((s) => s.cart, 'cart', isEmpty),
        isA<PosState>()
            .having((s) => s.promoCode, 'promo', isNull)
            .having((s) => s.discountAmount, 'diskon', 0.0),
      ],
      verify: (_) {
        verifyNever(
          () => datasource.validatePromo(
            code: any(named: 'code'),
            outletId: any(named: 'outletId'),
            subtotal: any(named: 'subtotal'),
          ),
        );
      },
    );

    blocTest<PosBloc, PosState>(
      'tanpa promo aktif: cart berubah tidak memanggil validatePromo',
      build: () => PosBloc(datasource: datasource),
      act: (bloc) => bloc.add(PosItemAdded(_makeItem())),
      expect: () => [isA<PosState>().having((s) => s.cart.length, 'cart', 1)],
      verify: (_) {
        verifyNever(
          () => datasource.validatePromo(
            code: any(named: 'code'),
            outletId: any(named: 'outletId'),
            subtotal: any(named: 'subtotal'),
          ),
        );
      },
    );
  });

  // ─── PosState Computed Properties ─────────────────────────────────────────

  group('PosState — filteredMenu', () {
    test('tanpa filter: semua item tampil', () {
      final state = PosState(
        menuItems: [
          _makeItem(id: 'a'),
          _makeItem(id: 'b'),
        ],
      );
      expect(state.filteredMenu.length, 2);
    });

    test('dengan filter categoryId: hanya item kategori itu yang tampil', () {
      final state = PosState(
        selectedCategoryId: 'cat-1',
        menuItems: [
          _makeItem(id: 'a', categoryId: 'cat-1'),
          _makeItem(id: 'b', categoryId: 'cat-2'),
          _makeItem(id: 'c', categoryId: 'cat-1'),
        ],
      );
      expect(state.filteredMenu.length, 2);
      expect(state.filteredMenu.map((m) => m.id), containsAll(['a', 'c']));
    });

    test('total dengan diskon = subtotal - discountAmount', () {
      final state = PosState(
        cart: [_makeCartItem(_makeItem(price: 50000))],
        discountAmount: 10000,
      );
      expect(state.subtotal, 50000);
      expect(state.total, 40000);
    });
  });
}

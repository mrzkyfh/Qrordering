import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qrordering/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';
import 'package:qrordering/features/pos/domain/entities/cart_item.dart';
import 'package:qrordering/features/pos/presentation/bloc/pos_bloc.dart';
import 'package:qrordering/features/pos/presentation/pages/pos_page.dart';
import 'package:qrordering/features/pos/presentation/widgets/cart_panel.dart';
import 'package:qrordering/features/pos/presentation/widgets/menu_item_card.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_category.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/profile.dart';

class MockPosDatasource extends Mock implements PosDatasource {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

MenuItem _item({
  String id = 'item-1',
  String name = 'Cendol',
  double price = 12000,
  bool allowPriceOverride = false,
}) => MenuItem(
  id: id,
  outletId: 'outlet-1',
  name: name,
  price: price,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  allowPriceOverride: allowPriceOverride,
  sortOrder: 0,
);

MenuCategory _cat() => MenuCategory(
  id: 'cat-1',
  outletId: 'outlet-1',
  name: 'Dessert',
  sortOrder: 0,
  isActive: true,
);

Profile _profile() => Profile(
  id: 'staff-1',
  outletId: 'outlet-1',
  role: UserRole.kasir,
  fullName: 'Kasir Uji',
  isActive: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late MockPosDatasource ds;
  late PosBloc posBloc;
  late MockAuthBloc authBloc;

  setUp(() {
    ds = MockPosDatasource();
    when(
      () => ds.fetchCategories('outlet-1'),
    ).thenAnswer((_) async => [_cat()]);
    when(
      () => ds.fetchMenuItems('outlet-1'),
    ).thenAnswer((_) async => [_item()]);
    when(
      () => ds.fetchOutletSettings(any()),
    ).thenAnswer((_) async => <String, dynamic>{});
    posBloc = PosBloc(datasource: ds);
    authBloc = MockAuthBloc();
    when(() => authBloc.state).thenReturn(AuthLoading());
  });

  tearDown(() => posBloc.close());

  Widget harness() => MaterialApp(
    home: MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<PosBloc>.value(value: posBloc),
      ],
      child: const Scaffold(body: PosPage()),
    ),
  );

  Widget cartHarness() => MaterialApp(
    home: MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<PosBloc>.value(value: posBloc),
      ],
      child: const Scaffold(body: SizedBox(width: 360, child: CartPanel())),
    ),
  );

  testWidgets('CartPanel reaktif: item masuk cart → tampil di Current Order', (
    tester,
  ) async {
    // Ukuran tablet realistis (POS dipakai di tablet) → grid menu 3 kolom muat.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Load menu (async mock perlu runAsync agar Future selesai)
    await tester.runAsync(() async {
      posBloc.add(PosMenuLoadRequested('outlet-1'));
      await posBloc.stream.firstWhere((s) => s.menuItems.isNotEmpty);
    });
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Awal: cart kosong → placeholder tampil
    expect(find.text('Belum ada item'), findsOneWidget);
    // Nama item tampil sekali (di kartu menu)
    expect(find.text('Cendol'), findsOneWidget);

    // Tambah item ke cart (mutasi di runAsync agar emit ter-propagasi ke BlocBuilder).
    await tester.runAsync(() async {
      posBloc.add(PosItemAdded(_item()));
      await posBloc.stream.firstWhere((s) => s.cart.isNotEmpty);
    });
    // pumpAndSettle: tuntaskan animasi one-shot (fadeIn/slideX) agar tak ada
    // timer menggantung saat teardown.
    await tester.pumpAndSettle();

    // CartPanel reaktif: placeholder hilang, item + ringkasan tampil.
    expect(find.text('Belum ada item'), findsNothing);
    expect(find.text('Cendol'), findsNWidgets(2)); // kartu menu + baris cart
    expect(find.text('Subtotal'), findsOneWidget);
    final clearCartButton = find.byKey(const Key('clear-cart-button'));
    expect(clearCartButton, findsOneWidget);
    expect(tester.getSize(clearCartButton).height, greaterThanOrEqualTo(40));
    expect(
      tester.getSize(find.byKey(const Key('cart-item-list'))).height,
      greaterThanOrEqualTo(100),
      reason: 'Daftar produk harus tetap terlihat pada layar tablet',
    );
    expect(
      tester.getSize(find.byKey(const Key('cart-footer-scroll'))).height,
      lessThanOrEqualTo(800 * 0.55),
    );
    expect(
      tester.getSize(find.byTooltip('Tambah jumlah')).height,
      greaterThanOrEqualTo(40),
    );
    expect(
      find.ancestor(
        of: find.text('Simpan ke Daftar Order'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Tahan Pesanan'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );

    await tester.tap(clearCartButton);
    await tester.pumpAndSettle();
    expect(find.text('Kosongkan Keranjang?'), findsOneWidget);
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    expect(posBloc.state.cart.length, 1);
  });

  testWidgets('produk harga fleksibel menampilkan input harga jual di kasir', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final flexible = _item(allowPriceOverride: true);
    when(
      () => ds.fetchMenuItems('outlet-1'),
    ).thenAnswer((_) async => [flexible]);
    await tester.runAsync(() async {
      posBloc.add(PosMenuLoadRequested('outlet-1'));
      await posBloc.stream.firstWhere((s) => s.menuItems.isNotEmpty);
    });
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cendol'));
    await tester.pumpAndSettle();
    expect(find.text('HARGA JUAL'), findsOneWidget);
    expect(find.text('Harga katalog Rp 12.000'), findsOneWidget);

    final priceField = find.byKey(const ValueKey('priceOverrideField'));
    await tester.enterText(priceField, '18000');
    await tester.tap(find.text('Tambah ke Pesanan'));
    await tester.pumpAndSettle();
    expect(posBloc.state.cart.single.unitPrice, 18000);
  });

  testWidgets('layar pendek tetap menyediakan ruang untuk daftar produk', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      posBloc.add(PosMenuLoadRequested('outlet-1'));
      await posBloc.stream.firstWhere((s) => s.menuItems.isNotEmpty);
      posBloc.add(PosItemAdded(_item()));
      await posBloc.stream.firstWhere((s) => s.cart.isNotEmpty);
    });
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('cart-item-list'))).height,
      greaterThanOrEqualTo(70),
    );
    expect(
      tester.getSize(find.byKey(const Key('cart-footer-scroll'))).height,
      lessThanOrEqualTo(600 * 0.55),
    );
  });

  testWidgets(
    'tablet split screen keeps categories, three product columns and cart',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        posBloc.add(PosMenuLoadRequested('outlet-1'));
        await posBloc.stream.firstWhere((s) => s.menuItems.isNotEmpty);
        posBloc.add(PosItemAdded(_item()));
        await posBloc.stream.firstWhere((s) => s.cart.isNotEmpty);
      });
      // Fullscreen, portrait and split windows, with common density settings.
      for (final density in [1.0, 1.5, 2.0]) {
        tester.view.devicePixelRatio = density;
        for (final size in [
          const Size(1340, 800),
          const Size(1280, 800),
          const Size(800, 1340),
          const Size(800, 1280),
          const Size(670, 800),
          const Size(640, 800),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(harness());
          await tester.pumpAndSettle();
          final card = find.byType(MenuItemCard).first;
          expect(tester.getSize(card).width, greaterThanOrEqualTo(130));
          expect(posBloc.state.itemCount, 1);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size at density $density',
          );
          final windowWidth = size.width / density;
          if (windowWidth < 400) {
            expect(find.text('Lihat Pesanan'), findsOneWidget);
          } else {
            expect(find.byType(CartPanel), findsOneWidget);
            expect(find.text('Lihat Pesanan'), findsNothing);
            if (windowWidth < 1100) {
              final categories = find.byKey(
                const Key('compact-category-panel'),
              );
              expect(categories, findsOneWidget);
              expect(
                tester.getTopLeft(categories).dx,
                lessThan(tester.getTopLeft(card).dx),
              );
              expect(
                tester.getTopLeft(card).dx,
                lessThan(tester.getTopLeft(find.byType(CartPanel)).dx),
              );
              final grid = tester.widget<GridView>(find.byType(GridView).first);
              expect(
                (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
                    .crossAxisCount,
                3,
              );
            }
          }
        }
      }
      await tester.tap(find.text('Lihat Pesanan'));
      await tester.pumpAndSettle();
      expect(find.byType(CartPanel), findsOneWidget);
      expect(find.text('Cendol'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved items require void for minus, swipe delete and clear cart',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        posBloc.add(
          PosCartLoaded([
            CartItem(id: 'stored', menuItem: _item(), quantity: 2),
          ], replaceOrderId: 'online-1'),
        );
        await posBloc.stream.firstWhere((s) => s.cart.isNotEmpty);
      });
      await tester.pumpWidget(cartHarness());
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      expect(find.text('Kode void diperlukan'), findsOneWidget);
      expect(posBloc.state.cart.single.quantity, 2);
      await tester.tap(find.text('Mengerti'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Kode void diperlukan'), findsOneWidget);
      expect(posBloc.state.cart.single.quantity, 2);
      await tester.tap(find.text('Mengerti'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('stored')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hapus'));
      await tester.pumpAndSettle();
      expect(find.text('Kode void diperlukan'), findsOneWidget);
      expect(posBloc.state.cart.single.quantity, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mode edit online hanya menampilkan aksi simpan perubahan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      posBloc.add(
        PosCartLoaded(
          [CartItem(id: 'cart-1', menuItem: _item(), quantity: 1)],
          orderType: OrderType.selfOrder,
          replaceOrderId: 'online-1',
          replaceOrderNumber: 'ON-001',
        ),
      );
      await posBloc.stream.firstWhere((s) => s.replaceOrderId != null);
    });
    await tester.pumpWidget(cartHarness());
    await tester.pumpAndSettle();

    expect(find.text('Mengedit pesanan online #ON-001'), findsOneWidget);
    expect(find.text('Simpan Perubahan #ON-001'), findsOneWidget);
    expect(find.text('Simpan ke Daftar Order'), findsNothing);
    expect(find.text('Tahan Pesanan'), findsNothing);
    expect(find.text('Bayar'), findsNothing);
    expect(find.text('Cetak Struk'), findsNothing);
  });

  testWidgets(
    'mode tambah order lama jelas, terkunci, dan bisa keluar ke transaksi baru',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        posBloc.add(
          PosCartLoaded(
            [CartItem(id: 'new-item', menuItem: _item(), quantity: 1)],
            orderType: OrderType.selfOrder,
            tableId: 'table-17',
            tableNumber: '17',
            appendOrderId: 'order-083',
            appendOrderNumber: '083',
          ),
        );
        await posBloc.stream.firstWhere((s) => s.appendOrderId != null);
      });
      await tester.pumpWidget(cartHarness());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('append-order-mode-banner')), findsOneWidget);
      expect(find.text('TAMBAH KE PESANAN #083'), findsOneWidget);
      expect(find.textContaining('Pesanan QR · Meja 17'), findsOneWidget);
      expect(find.text('Dine In'), findsNothing);
      expect(find.text('Takeaway'), findsNothing);
      expect(find.text('Nama pelanggan (opsional)...'), findsNothing);
      expect(find.text('Tambah ke Pesanan #083'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exit-append-order-button')));
      await tester.pumpAndSettle();
      expect(find.text('Keluar dari Tambah Pesanan?'), findsOneWidget);
      final exitedAppendMode = posBloc.stream.firstWhere(
        (state) => state.appendOrderId == null,
      );
      await tester.tap(
        find.byKey(const Key('confirm-exit-append-order-button')),
      );
      await tester.runAsync(() => exitedAppendMode);
      await tester.pumpAndSettle();

      expect(posBloc.state.appendOrderId, isNull);
      expect(posBloc.state.cart, isEmpty);
      expect(posBloc.state.tableId, isNull);
      expect(posBloc.state.tableNumber, isNull);
      expect(posBloc.state.orderType, OrderType.takeaway);
      expect(find.byKey(const Key('append-order-mode-banner')), findsNothing);
      expect(find.text('Takeaway', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('aksi yang sedang berjalan mengunci tombol transaksi lain', (
    tester,
  ) async {
    when(
      () => authBloc.state,
    ).thenReturn(AuthAuthenticated(profile: _profile()));
    await tester.runAsync(() async {
      posBloc.add(PosItemAdded(_item()));
      await posBloc.stream.firstWhere((s) => s.cart.isNotEmpty);
    });
    await tester.pumpWidget(cartHarness());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Tahan Pesanan'));
    await tester.tap(find.text('Tahan Pesanan'));
    await tester.pumpAndSettle();

    expect(find.text('Nama/label pesanan'), findsOneWidget);
    final printButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Cetak Struk', skipOffstage: false),
        matching: find.byType(OutlinedButton, skipOffstage: false),
      ),
    );
    expect(printButton.onPressed, isNull);

    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    final enabledPrintButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Cetak Struk'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(enabledPrintButton.onPressed, isNotNull);
  });
}

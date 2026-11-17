import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:qrordering/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qrordering/features/orders/presentation/bloc/orders_bloc.dart';
import 'package:qrordering/features/orders/presentation/pages/order_list_page.dart';
import 'package:qrordering/features/pos/presentation/bloc/shift_bloc.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/order.dart';
import 'package:qrordering/shared/models/shift.dart';
import 'package:qrordering/shared/widgets/badge_label.dart';
import 'package:qrordering/shared/widgets/order_button.dart';

class MockOrdersBloc extends MockBloc<OrdersEvent, OrdersState>
    implements OrdersBloc {}

class MockShiftBloc extends MockBloc<ShiftEvent, ShiftState>
    implements ShiftBloc {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

MenuItem _menu(String name) => MenuItem(
  id: 'm-$name',
  outletId: 'outlet-1',
  name: name,
  price: 15000,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  sortOrder: 0,
);

OrderItem _item(String orderId, String name, int qty) => OrderItem(
  id: '$orderId-$name',
  orderId: orderId,
  menuItemId: 'm-$name',
  quantity: qty,
  unitPrice: 15000,
  subtotal: 15000.0 * qty,
  menuItem: _menu(name),
);

Order _order({
  required String id,
  required OrderStatus status,
  required OrderType type,
  int itemCount = 3,
  double taxAmount = 0,
  double serviceCharge = 0,
  List<Payment>? payments,
  DateTime? createdAt,
  String? orderNumber,
}) {
  final items = List.generate(
    itemCount,
    (i) => _item(id, 'Menu Item Panjang Sekali $i', i % 3 + 1),
  );
  // Default hari ini — Daftar Order memfilter created_at = hari ini.
  final ts = createdAt ?? DateTime.now();
  return Order(
    id: id,
    outletId: 'outlet-1',
    orderNumber: orderNumber ?? id.toUpperCase(),
    orderType: type,
    status: status,
    subtotal: 50000,
    discountAmount: 0,
    taxAmount: taxAmount,
    serviceCharge: serviceCharge,
    totalAmount: 187360,
    stockDeducted: true,
    customerName: 'Budi Santoso',
    createdAt: ts,
    updatedAt: ts,
    items: items,
    payments: payments,
  );
}

void main() {
  late MockOrdersBloc bloc;
  late MockShiftBloc shiftBloc;
  late MockAuthBloc authBloc;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  setUp(() {
    bloc = MockOrdersBloc();
    shiftBloc = MockShiftBloc();
    authBloc = MockAuthBloc();
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: AuthDeviceRequired(),
    );
    final activeShift = Shift(
      id: 'shift-1',
      outletId: 'outlet-1',
      kasirId: 'cashier-1',
      startTime: DateTime.now().subtract(const Duration(hours: 1)),
      openingCash: 100000,
    );
    whenListen(
      shiftBloc,
      const Stream<ShiftState>.empty(),
      initialState: ShiftState(
        activeShift: activeShift,
        outletId: 'outlet-1',
        kasirId: 'cashier-1',
      ),
    );
  });

  void seed(List<Order> orders) {
    final state = OrdersState(outletId: 'outlet-1', activeOrders: orders);
    whenListen(bloc, const Stream<OrdersState>.empty(), initialState: state);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: authBloc,
        child: MaterialApp(
          home: BlocProvider<ShiftBloc>.value(
            value: shiftBloc,
            child: OrderListPage(bloc: bloc),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'render grid kartu order tanpa overflow (berbagai status & item)',
    (tester) async {
      seed([
        _order(id: 'o1', status: OrderStatus.confirmed, type: OrderType.dineIn),
        _order(
          id: 'o2',
          status: OrderStatus.preparing,
          type: OrderType.takeaway,
          itemCount: 4,
        ),
        _order(
          id: 'o3',
          status: OrderStatus.ready,
          type: OrderType.selfOrder,
          itemCount: 1,
        ),
        _order(
          id: 'o4',
          status: OrderStatus.served,
          type: OrderType.dineIn,
          itemCount: 6,
        ),
        _order(
          id: 'o5',
          status: OrderStatus.draft,
          type: OrderType.dineIn,
          itemCount: 0,
        ),
      ]);

      await pumpPage(tester);

      expect(tester.takeException(), isNull); // tidak ada overflow
      expect(find.text('Daftar Order'), findsOneWidget);
      expect(find.byType(BadgeLabel), findsWidgets);
      expect(find.byType(OrderButton), findsWidgets);
      expect(find.text('Ke Dapur'), findsWidgets); // draft → kasir pilih
      expect(find.text('Bayar'), findsWidgets); // draft + aktif belum bayar
      expect(find.text('Detail'), findsWidgets);
      expect(find.textContaining('lainnya'), findsWidgets); // order 6 item
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets('order void tidak tampil sebagai nota Lunas', (tester) async {
    seed([
      _order(
        id: 'void-kosong',
        status: OrderStatus.void_,
        type: OrderType.dineIn,
        itemCount: 0,
      ),
    ]);

    await pumpPage(tester);

    expect(find.text('VOID-KOSONG'), findsNothing);
    expect(find.text('Lunas'), findsNothing);
    expect(find.text('Belum ada order masuk'), findsOneWidget);
  });

  testWidgets(
    'tap Ke Dapur (draft) → status dan cetak dapur diproses',
    (tester) async {
      seed([
        _order(id: 'o1', status: OrderStatus.draft, type: OrderType.dineIn),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Ke Dapur').first);
      await tester.pump();

      verify(
        () => bloc.add(OrderSendToKitchenRequested('o1', 'outlet-1')),
      ).called(1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'dialog pembayaran menangkap ShiftBloc sebelum masuk root Navigator',
    (tester) async {
      seed([
        _order(
          id: 'bayar',
          status: OrderStatus.confirmed,
          type: OrderType.dineIn,
        ),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Bayar').first);
      await tester.pumpAndSettle();

      expect(find.text('Pembayaran'), findsOneWidget);
      expect(find.text('Bayar Sekarang'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets('order belum lunas menyediakan aksi Cetak Bill', (tester) async {
    seed([
      _order(
        id: 'tagihan',
        status: OrderStatus.confirmed,
        type: OrderType.dineIn,
      ),
    ]);

    await pumpPage(tester);
    await tester.tap(find.text('Detail').first);
    await tester.pumpAndSettle();

    expect(find.text('Cetak Bill'), findsOneWidget);
    expect(find.text('Bayar'), findsWidgets);
  });

  testWidgets(
    'order Ke Dapur lokal tetap menyediakan Bayar, tambah, bill, dan dapur',
    (tester) async {
      seed([
        _order(
          id: 'offline-active',
          status: OrderStatus.confirmed,
          type: OrderType.dineIn,
          orderNumber: 'OFFLINE',
        ),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Detail').first);
      await tester.pumpAndSettle();

      expect(find.text('Bayar'), findsWidgets);
      expect(find.text('Tambah Pesanan'), findsOneWidget);
      expect(find.text('Cetak Bill'), findsOneWidget);
      expect(find.text('Cetak Tiket Dapur'), findsOneWidget);
      expect(find.text('Pindah Meja'), findsNothing);
      expect(find.text('Gabung'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'order confirmed yang pembayaran penuhnya sudah tercatat tampil Lunas',
    (tester) async {
      seed([
        _order(
          id: 'qr-paid',
          status: OrderStatus.confirmed,
          type: OrderType.selfOrder,
          payments: [
            Payment(
              id: 'payment-full',
              orderId: 'qr-paid',
              outletId: 'outlet-1',
              method: PaymentMethod.cash,
              amount: 187360,
              paidAt: DateTime.now(),
            ),
          ],
        ),
      ]);

      await pumpPage(tester);

      final lunasBadge = find.descendant(
        of: find.byType(BadgeLabel),
        matching: find.text('Lunas'),
      );
      expect(lunasBadge, findsOneWidget);
      expect(find.text('Dikonfirmasi'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('PaymentSheet tidak membaca ShiftBloc dari BuildContext dialog', () {
    final source = File(
      'lib/features/orders/presentation/pages/order_list_page.dart',
    ).readAsStringSync();
    final start = source.indexOf('class _PaymentSheetState');
    final end = source.indexOf('class _MethodDropdown', start);
    final paymentState = source.substring(start, end);

    expect(paymentState, contains('widget.shiftBloc.state.activeShift'));
    expect(paymentState, isNot(contains('context.read<ShiftBloc>()')));
  });

  testWidgets(
    'order AKTIF kemarin tetap tampil; order LUNAS kemarin tidak',
    (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final state = OrdersState(
        outletId: 'outlet-1',
        activeOrders: [
          _order(
            id: 'aktif',
            status: OrderStatus.confirmed,
            type: OrderType.dineIn,
            createdAt: yesterday,
          ),
        ],
        completedOrders: [
          _order(
            id: 'lunas',
            status: OrderStatus.paid,
            type: OrderType.dineIn,
            createdAt: yesterday,
          ),
        ],
      );
      whenListen(bloc, const Stream<OrdersState>.empty(), initialState: state);

      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      expect(
        find.text('#AKTIF'),
        findsOneWidget,
      ); // aktif kemarin → tetap tampil
      expect(find.text('#LUNAS'), findsNothing); // lunas kemarin → tidak tampil
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'grid kosong → empty state, tanpa exception',
    (tester) async {
      seed([]);
      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Belum ada order'), findsOneWidget);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'modal detail order aktif tidak bottom overflow di landscape',
    (tester) async {
      tester.view.physicalSize = const Size(1060, 794);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seed([
        _order(
          id: 'o2',
          status: OrderStatus.confirmed,
          type: OrderType.takeaway,
          itemCount: 2,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<ShiftBloc>.value(
            value: shiftBloc,
            child: OrderListPage(bloc: bloc),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Detail').first);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Bagi'), findsNothing);
      expect(find.text('Tambah Pesanan'), findsOneWidget);
      expect(find.text('Cetak Tiket Dapur'), findsOneWidget);
      final voidButton = find.ancestor(
        of: find.text('Void Item'),
        matching: find.byType(OutlinedButton),
      );
      final kitchenButton = find.ancestor(
        of: find.text('Cetak Tiket Dapur'),
        matching: find.byType(OutlinedButton),
      );
      expect(
        tester.getSize(voidButton).width,
        greaterThan(tester.getSize(kitchenButton).width * 1.8),
        reason: 'Tombol Void Item harus memenuhi satu baris pada grid tablet',
      );
      await tester.tap(kitchenButton);
      await tester.pumpAndSettle();
      expect(find.text('Pilih Semua'), findsOneWidget);
      expect(find.text('0 item dipilih'), findsOneWidget);
      await tester.tap(find.byTooltip('Tutup'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(seconds: 1));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'pesanan online confirmed yang belum dibayar menampilkan Edit Pesanan',
    (tester) async {
      seed([
        _order(
          id: 'online-editable',
          status: OrderStatus.confirmed,
          type: OrderType.selfOrder,
          itemCount: 2,
        ),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Detail').first);
      await tester.pumpAndSettle();

      expect(find.text('Edit Pesanan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'pesanan online yang sudah masuk dapur tidak menawarkan Edit Pesanan',
    (tester) async {
      seed([
        _order(
          id: 'online-preparing',
          status: OrderStatus.preparing,
          type: OrderType.selfOrder,
          itemCount: 2,
        ),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Detail').first);
      await tester.pumpAndSettle();

      expect(find.text('Edit Pesanan'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'pesanan online confirmed yang sudah punya pembayaran tidak dapat diedit',
    (tester) async {
      final paidAt = DateTime.now();
      seed([
        _order(
          id: 'online-partially-paid',
          status: OrderStatus.confirmed,
          type: OrderType.selfOrder,
          itemCount: 2,
          payments: [
            Payment(
              id: 'payment-1',
              orderId: 'online-partially-paid',
              outletId: 'outlet-1',
              method: PaymentMethod.cash,
              amount: 1000,
              paidAt: paidAt,
            ),
          ],
        ),
      ]);

      await pumpPage(tester);
      await tester.tap(find.text('Detail').first);
      await tester.pumpAndSettle();

      expect(find.text('Edit Pesanan'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'Detail → Gabung responsif pada perangkat 360×800 tanpa overflow',
    (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      seed([
        _order(
          id: 'sumber',
          status: OrderStatus.confirmed,
          type: OrderType.dineIn,
          itemCount: 3,
          taxAmount: 10000,
          serviceCharge: 2140,
          createdAt: now,
        ),
        _order(
          id: 'tujuan',
          status: OrderStatus.confirmed,
          type: OrderType.dineIn,
          itemCount: 2,
          createdAt: now.subtract(const Duration(minutes: 1)),
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<ShiftBloc>.value(
            value: shiftBloc,
            child: OrderListPage(bloc: bloc),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Daftar order awal tidak boleh overflow pada layar 360×800',
      );
      await tester.tap(find.text('Detail').first);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('PELANGGAN'), findsOneWidget);
      expect(find.text('PESANAN'), findsOneWidget);
      expect(find.text('Gabung'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Gabung'));
      await tester.pump();
      await tester.tap(find.text('Gabung'));
      await tester.pumpAndSettle();

      expect(find.text('Gabung #SUMBER ke…'), findsOneWidget);
      expect(find.text('Order #TUJUAN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('Reusable widgets', () {
    testWidgets('OrderButton memanggil onPressed saat di-tap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OrderButton(
              label: 'Proses',
              backgroundColor: Colors.blue,
              textColor: Colors.white,
              onPressed: () => tapped = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Proses'));
      expect(tapped, true);
    });

    testWidgets('OrderButton nonaktif (onPressed null) tidak crash', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OrderButton(
              label: 'Lunas',
              backgroundColor: Colors.green,
              textColor: Colors.white,
              onPressed: null,
            ),
          ),
        ),
      );
      expect(find.text('Lunas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('BadgeLabel menampilkan teks', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BadgeLabel(
              text: 'Dine In',
              backgroundColor: Color(0xFF60A5FA),
              textColor: Color(0xFF1E3A8A),
            ),
          ),
        ),
      );
      expect(find.text('Dine In'), findsOneWidget);
    });
  });
}

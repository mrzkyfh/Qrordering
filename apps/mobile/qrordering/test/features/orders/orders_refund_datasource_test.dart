import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/features/orders/data/datasources/orders_datasource.dart';
import 'package:qrordering/features/orders/presentation/widgets/item_void_dialog.dart';
import 'package:qrordering/features/orders/presentation/widgets/partial_refund_dialog.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/order.dart';

class _FakeRefundApi {
  final requests = <({String path, Object? body})>[];
  late final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty ? null : jsonDecode(raw);
      requests.add((path: request.uri.path, body: body));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_reply(request.uri.path)));
      await request.response.close();
    });
  }

  Object _reply(String path) {
    if (path == '/rest/v1/order_items') {
      return [
        {
          'id': 'item-1',
          'quantity': 3,
          'refunded_qty': 1,
          'unit_price': 25000,
          'menu_items': {'name': 'Kebab Besar'},
        },
        {
          'id': 'item-2',
          'quantity': 1,
          'refunded_qty': null,
          'unit_price': 10000,
          'menu_items': null,
        },
        {
          'id': 'item-selesai',
          'quantity': 2,
          'refunded_qty': 2,
          'unit_price': 30000,
          'menu_items': {'name': 'Sudah Direfund'},
        },
      ];
    }
    if (path == '/rest/v1/rpc/refund_order_items') {
      return {'refund_id': 'refund-1', 'amount': 50000, 'approver': 'Manajer'};
    }
    if (path == '/rest/v1/rpc/void_order_items') {
      return {
        'order_id': 'order-1',
        'amount': 25000,
        'order_status': 'confirmed',
        'approver': 'Manajer',
      };
    }
    return [];
  }

  Map<String, dynamic> rpcBody(String name) =>
      (requests
                  .firstWhere((request) => request.path == '/rest/v1/rpc/$name')
                  .body
              as Map)
          .cast<String, dynamic>();

  Future<void> stop() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRefundApi api;
  late OrdersDatasource datasource;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    api = _FakeRefundApi();
    await api.start();
    await Supabase.initialize(
      url: api.url,
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
    datasource = OrdersDatasource();
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await api.stop();
  });

  Order order() {
    final now = DateTime(2026, 7, 25);
    return Order(
      id: 'order-1',
      outletId: 'outlet-1',
      orderNumber: 'KJ-001',
      orderType: OrderType.dineIn,
      status: OrderStatus.paid,
      subtotal: 85000,
      discountAmount: 0,
      taxAmount: 8500,
      serviceCharge: 1700,
      totalAmount: 95200,
      stockDeducted: true,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required RefundItemsLoader loadItems,
    RefundApproversLoader? loadApprovers,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: partialRefundSheetForTesting(
            order: order(),
            loadItems: loadItems,
            loadApprovers:
                loadApprovers ??
                (_) async => [
                  {
                    'id': 'manager-1',
                    'full_name': 'Manajer',
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
                ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  test(
    'item refund dibaca dengan qty tersisa dan harga yang konsisten',
    () async {
      final items = await datasource.fetchRefundableItems('order-1');

      expect(items, hasLength(2));
      expect(items.first, {
        'id': 'item-1',
        'name': 'Kebab Besar',
        'quantity': 3,
        'refunded_qty': 1,
        'unit_price': 25000.0,
      });
      expect(items.last['name'], 'Item');
      expect(items.last['refunded_qty'], 0);
      expect(items.last['unit_price'], 10000.0);
    },
  );

  testWidgets(
    'partial refund tanpa approver eligible menjelaskan dan tetap menampilkan akun terkunci',
    (tester) async {
      await pumpDialog(
        tester,
        loadItems: (_) async => [
          {
            'id': 'item-1',
            'name': 'Kebab Besar',
            'quantity': 1,
            'refunded_qty': 0,
            'unit_price': 25000.0,
          },
        ],
        loadApprovers: (_) async => [
          {
            'id': 'manager-locked',
            'full_name': 'Manajer Tanpa Akses',
            'role': 'manajer',
            'has_pin': true,
            'can_refund': false,
          },
        ],
      );

      expect(
        find.text('Tidak ada staf yang memiliki akses refund.'),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('Manajer Tanpa Akses'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    },
  );

  test(
    'refund sebagian mengirim item, alasan, PIN, dan approver bersama',
    () async {
      final approver = await datasource.refundOrderItems(
        'order-1',
        items: const [
          {'order_item_id': 'item-1', 'qty': 2},
        ],
        reason: 'Salah pesanan',
        approverPin: '1234',
        approverId: 'manager-1',
      );

      expect(approver, 'Manajer');
      expect(api.rpcBody('refund_order_items'), {
        'p_order': 'order-1',
        'p_items': [
          {'order_item_id': 'item-1', 'qty': 2},
        ],
        'p_reason': 'Salah pesanan',
        'p_approver_pin': '1234',
        'p_approver_id': 'manager-1',
      });
    },
  );

  test(
    'void item mengirim jumlah, alasan, PIN, dan approver bersama',
    () async {
      final result = await datasource.voidOrderItems(
        'order-1',
        items: const [
          {'order_item_id': 'item-1', 'qty': 1},
        ],
        reason: 'Pelanggan membatalkan satu menu',
        approverPin: '1234',
        approverId: 'manager-1',
      );

      expect(result['order_status'], 'confirmed');
      expect(api.rpcBody('void_order_items'), {
        'p_order': 'order-1',
        'p_items': [
          {'order_item_id': 'item-1', 'qty': 1},
        ],
        'p_reason': 'Pelanggan membatalkan satu menu',
        'p_approver_pin': '1234',
        'p_approver_id': 'manager-1',
      });
    },
  );

  testWidgets('dialog hanya menampilkan item yang masih dapat direfund', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      loadItems: (_) async => [
        {
          'id': 'item-1',
          'name': 'Kebab Besar',
          'quantity': 3,
          'refunded_qty': 1,
          'unit_price': 25000.0,
        },
      ],
    );

    expect(find.text('Refund Sebagian'), findsOneWidget);
    expect(find.text('Kebab Besar'), findsOneWidget);
    expect(find.text('Sudah Direfund'), findsNothing);
    expect(find.text('Disetujui oleh'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial refund menampilkan approver terkunci dan tidak memilih otomatis',
    (tester) async {
      await pumpDialog(
        tester,
        loadItems: (_) async => [
          {
            'id': 'item-1',
            'name': 'Kebab Besar',
            'quantity': 1,
            'refunded_qty': 0,
            'unit_price': 25000.0,
          },
        ],
      );

      expect(find.text('Disetujui oleh'), findsOneWidget);
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.initialValue, isNull);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('Manajer Tanpa Akses'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    },
  );

  testWidgets('gagal memuat refund menampilkan pesan dan tombol coba lagi', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      loadItems: (_) async => throw Exception('jaringan terputus'),
    );

    expect(find.text('Coba Lagi'), findsOneWidget);
    expect(find.textContaining('belum dapat dimuat'), findsOneWidget);
    expect(find.textContaining('Tidak ada atasan'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dialog void item mewajibkan pilihan, alasan, approver, dan PIN',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: itemVoidSheetForTesting(
              order: Order(
                id: 'order-1',
                outletId: 'outlet-1',
                orderNumber: 'KJ-001',
                orderType: OrderType.dineIn,
                status: OrderStatus.confirmed,
                subtotal: 75000,
                discountAmount: 0,
                taxAmount: 7500,
                serviceCharge: 1500,
                totalAmount: 84000,
                stockDeducted: true,
                createdAt: DateTime(2026, 7, 25),
                updatedAt: DateTime(2026, 7, 25),
              ),
              loadItems: (_) async => [
                {
                  'id': 'item-1',
                  'name': 'Kebab Besar',
                  'quantity': 3,
                  'unit_price': 25000.0,
                },
              ],
              loadApprovers: (_) async => [
                {
                  'id': 'manager-1',
                  'full_name': 'Manajer',
                  'role': 'manajer',
                  'has_pin': true,
                },
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Void Item'), findsOneWidget);
      expect(find.text('Kebab Besar'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Konfirmasi Void Item'),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Pilih Semua void memilih seluruh jumlah yang tersedia', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: itemVoidSheetForTesting(
            order: Order(
              id: 'order-1',
              outletId: 'outlet-1',
              orderNumber: 'KJ-001',
              orderType: OrderType.dineIn,
              status: OrderStatus.confirmed,
              subtotal: 95000,
              discountAmount: 0,
              taxAmount: 0,
              serviceCharge: 0,
              totalAmount: 95000,
              stockDeducted: true,
              createdAt: DateTime(2026, 7, 25),
              updatedAt: DateTime(2026, 7, 25),
            ),
            loadItems: (_) async => [
              {
                'id': 'item-1',
                'name': 'Kebab Besar',
                'quantity': 3,
                'unit_price': 25000.0,
              },
              {
                'id': 'item-2',
                'name': 'Es Teh',
                'quantity': 2,
                'unit_price': 10000.0,
              },
            ],
            loadApprovers: (_) async => [
              {
                'id': 'manager-1',
                'full_name': 'Manajer',
                'role': 'manajer',
                'has_pin': true,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('0 item dipilih'), findsOneWidget);
    await tester.tap(find.text('Pilih Semua'));
    await tester.pump();

    expect(find.text('5 item dipilih'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

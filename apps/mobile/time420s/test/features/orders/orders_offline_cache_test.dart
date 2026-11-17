import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:time420s/features/orders/data/datasources/orders_datasource.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/shared/services/connectivity_service.dart';
import 'package:time420s/shared/services/offline_queue_service.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/menu_item.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late SupabaseClient client;
  late int requestCount;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('orders_offline_cache_test');
    Hive.init(tmp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await Hive.openBox(OfflineQueueService.boxName);
    requestCount = 0;
    client = SupabaseClient(
      'http://offline-cache.test',
      'test-key',
      httpClient: MockClient((request) async {
        requestCount++;
        if (request.url.path.endsWith('/rpc/get_pos_sales_page')) {
          return http.Response(
            jsonEncode({
              'rows': const [],
              'total_sales': 125000,
              'total_transactions': 5,
              'average_sales': 25000,
              'has_more': false,
              'days': const {},
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    ConnectivityService.instance.online.value = true;
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await client.dispose();
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('daftar order memakai cache langsung ketika status offline', () async {
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'orders_active_outlet-1',
      jsonEncode([
        {
          'id': 'order-cache',
          'outlet_id': 'outlet-1',
          'order_number': 'L-001',
          'order_type': 'dine_in',
          'status': 'confirmed',
          'subtotal': 10000,
          'total_amount': 10000,
          'created_at': '2026-07-30T08:00:00Z',
          'updated_at': '2026-07-30T08:00:00Z',
          'order_items': const [],
        },
      ]),
    );
    ConnectivityService.instance.online.value = false;

    final orders = await OrdersDatasource(
      client: client,
    ).fetchActiveOrders('outlet-1');

    expect(orders.single.id, 'order-cache');
    expect(requestCount, 0, reason: 'cache offline tidak boleh menunggu HTTP');
  });

  test(
    'append offline langsung memperbarui item dan total cache order',
    () async {
      await Hive.box(PosDatasource.menuCacheBoxName).put(
        'orders_active_outlet-1',
        jsonEncode([
          {
            'id': 'order-cache',
            'outlet_id': 'outlet-1',
            'order_number': 'L-001',
            'order_type': 'dine_in',
            'status': 'confirmed',
            'subtotal': 10000,
            'discount_amount': 0,
            'loyalty_discount': 0,
            'tax_amount': 1000,
            'service_charge': 0,
            'total_amount': 11000,
            'stock_deducted': true,
            'created_at': '2026-07-30T08:00:00Z',
            'updated_at': '2026-07-30T08:00:00Z',
            'order_items': [
              {
                'id': 'old-item',
                'order_id': 'order-cache',
                'menu_item_id': 'old-menu',
                'quantity': 1,
                'unit_price': 10000,
                'subtotal': 10000,
              },
            ],
          },
        ]),
      );
      const menu = MenuItem(
        id: 'new-menu',
        outletId: 'outlet-1',
        name: 'Menu Tambahan',
        price: 20000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      );

      await PosDatasource().appendItemsToCachedOrder(
        outletId: 'outlet-1',
        orderId: 'order-cache',
        items: const [CartItem(id: 'cart-1', menuItem: menu, quantity: 2)],
        taxPercent: 10,
        taxActive: true,
        taxInclusive: false,
        serviceChargePercent: 5,
        roundingIncrement: 0,
      );
      ConnectivityService.instance.online.value = false;

      final order = (await OrdersDatasource(
        client: client,
      ).fetchActiveOrders('outlet-1')).single;
      expect(order.items, hasLength(2));
      expect(order.items!.last.menuItem?.name, 'Menu Tambahan');
      expect(order.subtotal, 50000);
      expect(order.taxAmount, 5000);
      expect(order.serviceCharge, 2500);
      expect(order.totalAmount, 57500);
      expect(requestCount, 0);
    },
  );

  test(
    'cache lama tidak menampilkan order void sebagai order selesai',
    () async {
      Map<String, dynamic> order(String id, String status) => {
        'id': id,
        'outlet_id': 'outlet-1',
        'order_number': id,
        'order_type': 'dine_in',
        'status': status,
        'subtotal': status == 'void' ? 0 : 10000,
        'total_amount': status == 'void' ? 0 : 10000,
        'created_at': '2026-09-25T08:00:00Z',
        'updated_at': '2026-09-25T08:00:00Z',
        'order_items': const [],
      };
      await Hive.box(PosDatasource.menuCacheBoxName).put(
        'orders_completed_outlet-1',
        jsonEncode([order('paid-1', 'paid'), order('void-1', 'void')]),
      );
      ConnectivityService.instance.online.value = false;

      final orders = await OrdersDatasource(
        client: client,
      ).fetchCompletedOrders('outlet-1');

      expect(orders.map((order) => order.id), ['paid-1']);
      expect(requestCount, 0);
    },
  );

  test('daftar meja memakai snapshot lokal ketika offline', () async {
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'tables_outlet-1',
      jsonEncode([
        {
          'id': 'table-1',
          'table_number': '7',
          'area': 'Indoor',
          'status': 'available',
        },
      ]),
    );
    ConnectivityService.instance.online.value = false;

    final tables = await OrdersDatasource(
      client: client,
    ).fetchTables('outlet-1');

    expect(tables.single['table_number'], '7');
    expect(requestCount, 0);
  });

  test('order confirmed di outbox tetap terlihat tanpa cache server', () async {
    final payload = <String, dynamic>{
      'kind': 'confirmed',
      'clientOrderId': 'offline-confirmed',
      'outletId': 'outlet-1',
      'createdBy': 'staff-1',
      'orderType': 'dine_in',
      'tableId': null,
      'customerName': 'Rina',
      'subtotal': 12000,
      'discountAmount': 0,
      'taxAmount': 0,
      'serviceCharge': 0,
      'total': 12000,
      'createdAt': '2026-10-02T08:00:00Z',
      'items': [
        {
          'menuItemId': 'menu-1',
          'name': 'Nasi Goreng',
          'quantity': 1,
          'unitPrice': 12000,
          'subtotal': 12000,
          'extras': const [],
        },
      ],
    };
    await OfflineQueueService.instance.enqueue(payload);
    ConnectivityService.instance.online.value = false;

    final orders = await OrdersDatasource(
      client: client,
    ).fetchActiveOrders('outlet-1');

    expect(orders.single.id, 'offline-confirmed');
    expect(orders.single.status, OrderStatus.confirmed);
    expect(orders.single.items!.single.menuItem!.name, 'Nasi Goreng');
    expect(requestCount, 0);
  });

  test(
    'item tambahan order lokal digabung ke outbox induk tanpa hilang',
    () async {
      final payload = <String, dynamic>{
        'kind': 'confirmed',
        'clientOrderId': 'offline-append-parent',
        'outletId': 'outlet-1',
        'createdBy': 'staff-1',
        'orderType': 'dine_in',
        'subtotal': 10000,
        'discountAmount': 0,
        'loyaltyDiscount': 0,
        'taxAmount': 1000,
        'serviceCharge': 0,
        'total': 11000,
        'createdAt': '2026-10-02T08:00:00Z',
        'items': [
          {
            'menuItemId': 'menu-old',
            'name': 'Menu Lama',
            'quantity': 1,
            'unitPrice': 10000,
            'subtotal': 10000,
            'extras': const [],
          },
        ],
      };
      await OfflineQueueService.instance.enqueue(payload);
      const newMenu = MenuItem(
        id: 'menu-new',
        outletId: 'outlet-1',
        name: 'Menu Baru',
        price: 20000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      );

      final updated = await PosDatasource().appendItemsToQueuedOrder(
        outletId: 'outlet-1',
        orderId: 'offline-append-parent',
        items: const [CartItem(id: 'cart-new', menuItem: newMenu, quantity: 2)],
        taxPercent: 10,
        taxActive: true,
        taxInclusive: false,
        serviceChargePercent: 5,
        roundingIncrement: 0,
      );

      expect(updated, isNotNull);
      expect(updated!['items'], hasLength(2));
      expect(updated['subtotal'], 50000);
      expect(updated['taxAmount'], 5000);
      expect(updated['serviceCharge'], 2500);
      expect(updated['total'], 57500);
      expect(OfflineQueueService.instance.all(), hasLength(1));
      await OrdersDatasource(client: client).cacheQueuedOrder(updated);
      ConnectivityService.instance.online.value = false;

      final order = (await OrdersDatasource(
        client: client,
      ).fetchActiveOrders('outlet-1')).single;
      expect(order.items, hasLength(2));
      expect(order.items!.map((item) => item.menuItem!.name), [
        'Menu Lama',
        'Menu Baru',
      ]);
      expect(order.totalAmount, 57500);
      expect(requestCount, 0);
    },
  );

  test(
    'order lokal Ke Dapur dapat diubah menjadi lunas dalam outbox',
    () async {
      final payload = <String, dynamic>{
        'kind': 'confirmed',
        'clientOrderId': 'offline-pay-later',
        'outletId': 'outlet-1',
        'createdBy': 'staff-1',
        'orderType': 'dine_in',
        'tableId': 'table-1',
        'customerName': 'Rina',
        'subtotal': 12000,
        'discountAmount': 0,
        'taxAmount': 0,
        'serviceCharge': 0,
        'total': 12000,
        'createdAt': '2026-10-02T08:00:00Z',
        'items': [
          {
            'menuItemId': 'menu-1',
            'name': 'Nasi Goreng',
            'quantity': 1,
            'unitPrice': 12000,
            'subtotal': 12000,
            'extras': const [],
          },
        ],
      };
      await OfflineQueueService.instance.enqueue(payload);
      final updated = await OfflineQueueService.instance
          .updateByClientOrderId('offline-pay-later', {
            'kind': 'paid',
            'shiftId': 'shift-1',
            'paymentMethod': 'cash',
            'amount': 12000,
            'idempotencyKey': 'payment-1',
            'paidAt': '2026-10-02T09:30:00Z',
          });
      expect(updated, isNotNull);
      await OrdersDatasource(client: client).cacheQueuedOrder(updated!);
      ConnectivityService.instance.online.value = false;

      final datasource = OrdersDatasource(client: client);
      expect(await datasource.fetchActiveOrders('outlet-1'), isEmpty);
      final completed = await datasource.fetchCompletedOrders('outlet-1');
      expect(completed.single.id, 'offline-pay-later');
      expect(completed.single.status, OrderStatus.paid);
      expect(completed.single.paidTotal, 12000);
      expect(
        completed.single.payments!.single.paidAt,
        DateTime.parse('2026-10-02T09:30:00Z'),
      );
      expect(requestCount, 0);
    },
  );

  test(
    'split order lokal tetap aktif lalu pindah ke selesai saat lunas',
    () async {
      final payload = <String, dynamic>{
        'kind': 'confirmed',
        'clientOrderId': 'offline-split-local',
        'outletId': 'outlet-1',
        'createdBy': 'staff-1',
        'orderType': 'dine_in',
        'subtotal': 12000,
        'total': 12000,
        'createdAt': '2026-10-02T08:00:00Z',
        'items': [
          {
            'menuItemId': 'menu-1',
            'name': 'Nasi Goreng',
            'quantity': 1,
            'unitPrice': 12000,
            'subtotal': 12000,
            'extras': const [],
          },
        ],
      };
      await OfflineQueueService.instance.enqueue(payload);
      var updated = await OfflineQueueService.instance.updateByClientOrderId(
        'offline-split-local',
        {
          'shiftId': 'shift-1',
          'payments': const [
            {
              'method': 'cash',
              'amount': 5000,
              'idempotencyKey': 'split-cash',
              'paidAt': '2026-10-02T09:00:00Z',
              'paidAtClockSource': 'server_offset',
            },
          ],
        },
      );
      await OrdersDatasource(client: client).cacheQueuedOrder(updated!);
      ConnectivityService.instance.online.value = false;
      var datasource = OrdersDatasource(client: client);
      var active = await datasource.fetchActiveOrders('outlet-1');
      expect(active.single.paidTotal, 5000);
      expect(await datasource.fetchCompletedOrders('outlet-1'), isEmpty);

      updated = await OfflineQueueService.instance.updateByClientOrderId(
        'offline-split-local',
        {
          'kind': 'paid',
          'paidAt': '2026-10-02T09:05:00Z',
          'paidAtClockSource': 'server_offset',
          'payments': const [
            {
              'method': 'cash',
              'amount': 5000,
              'idempotencyKey': 'split-cash',
              'paidAt': '2026-10-02T09:00:00Z',
              'paidAtClockSource': 'server_offset',
            },
            {
              'method': 'qris',
              'amount': 7000,
              'idempotencyKey': 'split-qris',
              'paidAt': '2026-10-02T09:05:00Z',
              'paidAtClockSource': 'server_offset',
            },
          ],
        },
      );
      await datasource.cacheQueuedOrder(updated!);
      datasource = OrdersDatasource(client: client);
      active = await datasource.fetchActiveOrders('outlet-1');
      final completed = await datasource.fetchCompletedOrders('outlet-1');

      expect(active, isEmpty);
      expect(completed.single.status, OrderStatus.paid);
      expect(completed.single.payments, hasLength(2));
      expect(completed.single.paidTotal, 12000);
      expect(requestCount, 0);
    },
  );

  test('pembayaran split offline tersimpan idempoten di order aktif', () async {
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'orders_active_outlet-1',
      jsonEncode([
        {
          'id': 'order-cache',
          'outlet_id': 'outlet-1',
          'order_number': 'L-001',
          'order_type': 'dine_in',
          'status': 'confirmed',
          'subtotal': 10000,
          'total_amount': 10000,
          'created_at': '2026-10-02T08:00:00Z',
          'updated_at': '2026-10-02T08:00:00Z',
          'payments': const [],
          'order_items': const [],
        },
      ]),
    );
    final datasource = OrdersDatasource(client: client);

    for (var retry = 0; retry < 2; retry++) {
      await datasource.applyCachedPayment(
        outletId: 'outlet-1',
        orderId: 'order-cache',
        paymentId: 'payment-idempotent',
        method: PaymentMethod.cash,
        amount: 4000,
        paidAt: '2026-10-02T09:00:00Z',
        finalize: false,
      );
    }
    ConnectivityService.instance.online.value = false;

    final order = (await datasource.fetchActiveOrders('outlet-1')).single;
    expect(order.status, OrderStatus.confirmed);
    expect(order.payments, hasLength(1));
    expect(order.paidTotal, 4000);
    expect(requestCount, 0);
  });

  test(
    'pembayaran lunas offline memindahkan order ke daftar selesai',
    () async {
      await Hive.box(PosDatasource.menuCacheBoxName).put(
        'orders_active_outlet-1',
        jsonEncode([
          {
            'id': 'order-cache',
            'outlet_id': 'outlet-1',
            'order_number': 'L-001',
            'order_type': 'dine_in',
            'status': 'served',
            'subtotal': 10000,
            'total_amount': 10000,
            'created_at': '2026-10-02T08:00:00Z',
            'updated_at': '2026-10-02T08:00:00Z',
            'payments': const [],
            'order_items': const [],
          },
        ]),
      );
      final datasource = OrdersDatasource(client: client);

      await datasource.applyCachedPayment(
        outletId: 'outlet-1',
        orderId: 'order-cache',
        paymentId: 'payment-final',
        method: PaymentMethod.qris,
        amount: 10000,
        paidAt: '2026-10-02T09:00:00Z',
        finalize: true,
      );
      ConnectivityService.instance.online.value = false;

      expect(await datasource.fetchActiveOrders('outlet-1'), isEmpty);
      final completed = await datasource.fetchCompletedOrders('outlet-1');
      expect(completed.single.id, 'order-cache');
      expect(completed.single.status, OrderStatus.paid);
      expect(completed.single.paidTotal, 10000);
      expect(requestCount, 0);
    },
  );

  test(
    'riwayat penjualan memakai snapshot cache tanpa request kedua',
    () async {
      final datasource = OrdersDatasource(client: client);
      final online = await datasource.fetchSalesPage('outlet-1');
      expect(online.totalTransactions, 5);
      expect(requestCount, 1);

      ConnectivityService.instance.online.value = false;
      final cached = await datasource.fetchSalesPage('outlet-1');

      expect(cached.totalSales, 125000);
      expect(cached.totalTransactions, 5);
      expect(
        requestCount,
        1,
        reason: 'riwayat offline harus langsung dari cache',
      );
    },
  );

  test(
    'filter penjualan fallback ke query kompatibel saat RPC ditolak server',
    () async {
      var fallbackRequestCount = 0;
      final fallbackClient = SupabaseClient(
        'http://offline-cache.test',
        'test-key',
        httpClient: MockClient((request) async {
          fallbackRequestCount++;
          if (request.url.path.endsWith('/rpc/get_pos_sales_page')) {
            return http.Response(
              jsonEncode({
                'code': '57014',
                'message': 'canceling statement due to statement timeout',
                'details': null,
                'hint': null,
              }),
              400,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );

      try {
        final result = await OrdersDatasource(
          client: fallbackClient,
        ).fetchSalesPage('outlet-1', kind: 'takeaway');

        expect(result.orders, isEmpty);
        expect(result.totalSales, 0);
        expect(result.totalTransactions, 0);
        expect(
          fallbackRequestCount,
          greaterThan(1),
          reason: 'setelah RPC gagal harus mencoba query tabel kompatibel',
        );
      } finally {
        await fallbackClient.dispose();
      }
    },
  );
}

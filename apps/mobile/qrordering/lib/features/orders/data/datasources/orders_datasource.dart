import 'dart:async';
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/config/app_config.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/offline_queue_service.dart';
import '../../../../shared/services/order_realtime_service.dart';
import '../../../../shared/services/backend_request.dart' as backend;

class SalesDaySummary {
  final double total;
  final int count;

  const SalesDaySummary({required this.total, required this.count});
}

class SalesPageResult {
  final List<Order> orders;
  final Map<String, String> cashiers;
  final Map<String, double> netAmounts;
  final Map<String, DateTime> salesAt;
  final double totalSales;
  final int totalTransactions;
  final double averageSales;
  final bool hasMore;
  final Map<String, SalesDaySummary> days;

  const SalesPageResult({
    required this.orders,
    required this.cashiers,
    required this.netAmounts,
    required this.salesAt,
    required this.totalSales,
    required this.totalTransactions,
    required this.averageSales,
    required this.hasMore,
    required this.days,
  });
}

class OrderPaymentSnapshot {
  final double totalAmount;
  final double paidTotal;
  final String status;

  const OrderPaymentSnapshot({
    required this.totalAmount,
    required this.paidTotal,
    required this.status,
  });

  double get remaining => (totalAmount - paidTotal).clamp(0, double.infinity);
}

SalesPageResult salesPageResultFromPayload(Object? payload) {
  final root = payload is Map
      ? Map<String, dynamic>.from(payload)
      : <String, dynamic>{};
  final rows = (root['rows'] as List? ?? const [])
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  final cashiers = <String, String>{};
  final netAmounts = <String, double>{};
  final salesAt = <String, DateTime>{};
  for (final row in rows) {
    final orderId = row['id'];
    final id = row['created_by'];
    final name = row['cashier_name'];
    if (id is String && name is String && name.trim().isNotEmpty) {
      cashiers[id] = name;
    }
    if (orderId is String) {
      netAmounts[orderId] =
          (row['net_total_amount'] as num?)?.toDouble() ??
          (row['total_amount'] as num?)?.toDouble() ??
          0;
      final rawSalesAt = row['sales_at'] ?? row['created_at'];
      if (rawSalesAt is String) {
        final parsed = DateTime.tryParse(rawSalesAt);
        if (parsed != null) salesAt[orderId] = parsed;
      }
    }
  }

  final days = <String, SalesDaySummary>{};
  final rawDays = root['days'];
  if (rawDays is Map) {
    for (final entry in rawDays.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      days[entry.key.toString()] = SalesDaySummary(
        total: (value['total'] as num?)?.toDouble() ?? 0,
        count: (value['count'] as num?)?.toInt() ?? 0,
      );
    }
  }

  return SalesPageResult(
    orders: rows.map(Order.fromJson).toList(),
    cashiers: cashiers,
    netAmounts: netAmounts,
    salesAt: salesAt,
    totalSales: (root['total_sales'] as num?)?.toDouble() ?? 0,
    totalTransactions: (root['total_transactions'] as num?)?.toInt() ?? 0,
    averageSales: (root['average_sales'] as num?)?.toDouble() ?? 0,
    hasMore: root['has_more'] == true,
    days: days,
  );
}

class OrdersDatasource {
  static const cacheBoxName = 'menu_cache_secure_v1';
  static const legacyCacheBoxName = 'menu_cache';
  final SupabaseClient? _injectedClient;
  final SupabaseClient? _injectedFallbackClient;

  OrdersDatasource({SupabaseClient? client, SupabaseClient? fallbackClient})
    : _injectedClient = client,
      _injectedFallbackClient = fallbackClient;

  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  static const _uuid = Uuid();
  Box? get _offlineCache =>
      Hive.isBoxOpen(cacheBoxName) ? Hive.box(cacheBoxName) : null;

  List<Order>? _cachedOrders(String key) {
    final raw = _offlineCache?.get(key) as String?;
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List)
          .map(
            (entry) => Order.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .toList();
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>>? _cachedMaps(String key) {
    final raw = _offlineCache?.get(key) as String?;
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _queuedOrderMap(Map<String, dynamic> payload) {
    final outletId = payload['outletId'] as String?;
    final orderId = payload['clientOrderId'] as String?;
    final createdAt = payload['createdAt'] as String?;
    final kind = payload['kind'] as String?;
    final rawItems = payload['items'];
    if (outletId == null ||
        orderId == null ||
        createdAt == null ||
        rawItems is! List ||
        !const {'draft', 'confirmed', 'paid'}.contains(kind)) {
      return null;
    }

    final cachedMenu = _cachedMaps('item_$outletId') ?? const [];
    final menuById = <String, Map<String, dynamic>>{
      for (final menu in cachedMenu)
        if (menu['id'] is String) menu['id'] as String: menu,
    };
    final tableId = payload['tableId'] as String?;
    final tables = _cachedMaps('tables_$outletId') ?? const [];
    final table = tables.where((entry) => entry['id'] == tableId).firstOrNull;
    final payments = <Map<String, dynamic>>[];
    final rawPayments = payload['payments'];
    if (rawPayments is List && rawPayments.isNotEmpty) {
      for (var i = 0; i < rawPayments.length; i++) {
        final raw = rawPayments[i];
        if (raw is! Map) continue;
        payments.add({
          'id': raw['idempotencyKey'] ?? '$orderId-payment-$i',
          'order_id': orderId,
          'outlet_id': outletId,
          'method': raw['method'],
          'amount': raw['amount'],
          'paid_at': raw['paidAt'] ?? payload['paidAt'] ?? createdAt,
        });
      }
    } else if (kind == 'paid') {
      payments.add({
        'id': payload['idempotencyKey'] ?? '$orderId-payment',
        'order_id': orderId,
        'outlet_id': outletId,
        'method': payload['paymentMethod'],
        'amount': payload['amount'],
        'paid_at': payload['paidAt'] ?? createdAt,
      });
    }

    return {
      'id': orderId,
      'outlet_id': outletId,
      'shift_id': payload['shiftId'],
      'table_id': tableId,
      'order_number': payload['localReceiptNo'] ?? 'OFFLINE',
      'order_type': payload['orderType'],
      'status': kind == 'paid' ? 'paid' : kind,
      'customer_name': payload['customerName'],
      'subtotal': payload['subtotal'] ?? 0,
      'discount_amount': payload['discountAmount'] ?? 0,
      'tax_amount': payload['taxAmount'] ?? 0,
      'service_charge': payload['serviceCharge'] ?? 0,
      'total_amount': payload['total'] ?? 0,
      'stock_deducted': false,
      'kitchen_printed': payload['localKitchenPrinted'] == true,
      'created_by': payload['createdBy'],
      'created_at': createdAt,
      'updated_at': createdAt,
      'restaurant_tables': table == null
          ? null
          : {'table_number': table['table_number']},
      'payments': payments,
      'order_items': [
        for (var index = 0; index < rawItems.length; index++)
          if (rawItems[index] is Map)
            () {
              final item = Map<String, dynamic>.from(rawItems[index] as Map);
              final menuId = item['menuItemId'] as String? ?? '';
              final cached = menuById[menuId];
              final menu = cached == null
                  ? <String, dynamic>{
                      'id': menuId,
                      'outlet_id': outletId,
                      'name': item['name'] ?? 'Item',
                      'price': item['unitPrice'] ?? 0,
                      'is_available': true,
                      'is_active': true,
                      'is_featured': false,
                      'sort_order': 0,
                    }
                  : Map<String, dynamic>.from(cached);
              return <String, dynamic>{
                'id': '$orderId-item-$index',
                'order_id': orderId,
                'menu_item_id': menuId,
                'quantity': item['quantity'],
                'unit_price': item['unitPrice'],
                'subtotal': item['subtotal'],
                'notes': item['notes'],
                'menu_items': menu,
                'order_item_options': [
                  for (final rawExtra in item['extras'] as List? ?? const [])
                    if (rawExtra is Map)
                      {
                        'extra_name': rawExtra['extraName'] ?? '',
                        'option_name': rawExtra['optionName'] ?? '',
                        'price': rawExtra['price'] ?? 0,
                      },
                ],
              };
            }(),
      ],
    };
  }

  List<Order> _mergeQueuedOrders(
    List<Order> orders,
    String outletId, {
    required bool completed,
  }) {
    final merged = List<Order>.of(orders);
    for (final entry in OfflineQueueService.instance.all()) {
      final payload = entry.value;
      if (payload['outletId'] != outletId) continue;
      final kind = payload['kind'];
      if ((kind == 'paid') != completed) continue;
      final raw = _queuedOrderMap(payload);
      if (raw == null) continue;
      final local = Order.fromJson(raw);
      merged.removeWhere((order) => order.id == local.id);
      merged.insert(0, local);
    }
    return merged;
  }

  /// Order outbox milik outlet dalam bentuk model lengkap untuk tampilan.
  /// Satu pemetaan dipakai bersama datasource dan halaman Daftar Order agar
  /// status `confirmed`, nomor meja, opsi, serta pembayaran offline tidak
  /// berubah hanya karena UI membangun salinan payload yang berbeda.
  List<Order> queuedOrders(String outletId) => [
    ..._mergeQueuedOrders(const <Order>[], outletId, completed: false),
    ..._mergeQueuedOrders(const <Order>[], outletId, completed: true),
  ];

  static const _listItemSelect =
      'id, order_id, menu_item_id, quantity, unit_price, subtotal, notes, '
      'menu_items(id, outlet_id, name, price, is_available, is_active, '
      'is_featured, sort_order), '
      'order_item_options(extra_name, option_name, price)';

  Future<List<Order>> fetchActiveOrders(String outletId) async {
    final key = 'orders_active_$outletId';
    if (!ConnectivityService.instance.online.value) {
      final cached = _cachedOrders(key);
      if (cached != null) {
        return _mergeQueuedOrders(cached, outletId, completed: false);
      }
      final queued = _mergeQueuedOrders(
        const <Order>[],
        outletId,
        completed: false,
      );
      if (queued.isNotEmpty) return queued;
    }
    try {
      final data = await _client
          .from('orders')
          .select(
            '*, restaurant_tables(table_number), payments(id, amount), '
            'order_items($_listItemSelect)',
          )
          .eq('outlet_id', outletId)
          .inFilter('status', [
            'draft',
            'confirmed',
            'preparing',
            'ready',
            'served',
          ])
          .order('created_at', ascending: false);
      await _offlineCache?.put(key, jsonEncode(data));
      return _mergeQueuedOrders(
        (data as List).map((e) => Order.fromJson(e)).toList(),
        outletId,
        completed: false,
      );
    } catch (_) {
      final cached = _cachedOrders(key);
      if (cached != null) {
        return _mergeQueuedOrders(cached, outletId, completed: false);
      }
      rethrow;
    }
  }

  Future<List<Order>> fetchCompletedOrders(String outletId) async {
    // Hanya order selesai HARI INI (Daftar Order memang per-hari). Filter
    // server-side dari awal hari (lokal → UTC) agar semua transaksi lunas
    // hari ini ikut terambil, bukan terpotong limit pada outlet ramai.
    final now = DateTime.now();
    final startOfDayUtc = DateTime(
      now.year,
      now.month,
      now.day,
    ).toUtc().toIso8601String();
    final key = 'orders_completed_$outletId';
    if (!ConnectivityService.instance.online.value) {
      final cached = _cachedOrders(key);
      if (cached != null) {
        return _mergeQueuedOrders(
          cached.where((order) => order.status != OrderStatus.void_).toList(),
          outletId,
          completed: true,
        );
      }
      final queued = _mergeQueuedOrders(
        const <Order>[],
        outletId,
        completed: true,
      );
      if (queued.isNotEmpty) return queued;
    }
    try {
      final data = await _client
          .from('orders')
          .select(
            '*, restaurant_tables(table_number), '
            'order_items($_listItemSelect)',
          )
          .eq('outlet_id', outletId)
          .inFilter('status', ['paid', 'cancelled'])
          .gte('created_at', startOfDayUtc)
          .order('created_at', ascending: false)
          // Cukup untuk outlet sangat ramai (target ~500 order/hari) tanpa
          // memotong daftar bila suatu hari melampaui 500.
          .limit(1000);
      await _offlineCache?.put(key, jsonEncode(data));
      return _mergeQueuedOrders(
        (data as List)
            .map((e) => Order.fromJson(e))
            .where((order) => order.status != OrderStatus.void_)
            .toList(),
        outletId,
        completed: true,
      );
    } catch (_) {
      final cached = _cachedOrders(key);
      if (cached != null) {
        return _mergeQueuedOrders(
          cached.where((order) => order.status != OrderStatus.void_).toList(),
          outletId,
          completed: true,
        );
      }
      rethrow;
    }
  }

  /// Penjualan = order yang sudah dibayar (paid), dengan info pembayaran.
  Future<List<Order>> fetchSales(String outletId, {String? createdBy}) async {
    var query = _client
        .from('orders')
        .select('*, restaurant_tables(table_number), payments(*)')
        .eq('outlet_id', outletId)
        .eq('status', 'paid');
    if (createdBy != null) query = query.eq('created_by', createdBy);
    final data = await query.order('created_at', ascending: false).limit(1000);
    return (data as List).map((e) => Order.fromJson(e)).toList();
  }

  /// Daftar penjualan ringkas dengan filter, agregat, dan pagination yang
  /// seluruhnya dikerjakan database. Tidak memuat order_items/payments.
  Future<SalesPageResult> fetchSalesPage(
    String outletId, {
    String? createdBy,
    String kind = 'semua',
    DateTime? dateFrom,
    DateTime? dateTo,
    String? search,
    int offset = 0,
    int limit = 50,
  }) async {
    final cacheKey =
        'sales_page_${base64Url.encode(utf8.encode(jsonEncode({'outlet': outletId, 'createdBy': createdBy, 'kind': kind, 'from': dateFrom?.toUtc().toIso8601String(), 'to': dateTo?.toUtc().toIso8601String(), 'search': search?.trim(), 'offset': offset, 'limit': limit})))}';
    if (!ConnectivityService.instance.online.value) {
      final raw = _offlineCache?.get(cacheKey) as String?;
      if (raw != null) return salesPageResultFromPayload(jsonDecode(raw));
    }
    try {
      final data = await _client.rpc(
        'get_pos_sales_page',
        params: {
          'p_outlet_id': outletId,
          'p_created_by': createdBy,
          'p_kind': kind,
          'p_date_from': dateFrom?.toUtc().toIso8601String(),
          'p_date_to': dateTo?.toUtc().toIso8601String(),
          'p_search': search?.trim().isEmpty == true ? null : search?.trim(),
          'p_offset': offset,
          'p_limit': limit,
        },
      );
      await _offlineCache?.put(cacheKey, jsonEncode(data));
      return salesPageResultFromPayload(data);
    } on PostgrestException catch (rpcError, rpcStack) {
      // Selama proses rollout, APK/web baru dapat lebih dulu aktif daripada
      // migrasi RPC. Jangan membuat halaman Penjualan mati total ketika RPC
      // lama menolak filter baru, mengalami timeout, atau schema cache belum
      // diperbarui. Query tabel biasa tetap tunduk pada RLS yang sama.
      try {
        return await _legacySalesPage(
          outletId,
          createdBy: createdBy,
          kind: kind,
          dateFrom: dateFrom,
          dateTo: dateTo,
          search: search,
          offset: offset,
          limit: limit,
        );
      } catch (_) {
        final raw = _offlineCache?.get(cacheKey) as String?;
        if (raw != null) return salesPageResultFromPayload(jsonDecode(raw));
        Error.throwWithStackTrace(rpcError, rpcStack);
      }
    } catch (_) {
      final raw = _offlineCache?.get(cacheKey) as String?;
      if (raw != null) return salesPageResultFromPayload(jsonDecode(raw));
      rethrow;
    }
  }

  Future<SalesPageResult> _legacySalesPage(
    String outletId, {
    String? createdBy,
    required String kind,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? search,
    required int offset,
    required int limit,
  }) async {
    final fromUtc = dateFrom?.toUtc();
    final toUtc = dateTo?.toUtc();
    final query = search?.trim().toLowerCase() ?? '';
    final all =
        (await fetchSales(outletId, createdBy: createdBy)).where((order) {
          final kindMatches = switch (kind) {
            'dinein' => order.orderType == OrderType.dineIn,
            'takeaway' => order.orderType == OrderType.takeaway,
            'online' => order.orderType == OrderType.selfOrder,
            // Kompatibilitas untuk APK lama. UI baru memakai filter `takeaway`
            // agar setiap jenis transaksi saling eksklusif.
            'kasir' => order.orderType != OrderType.selfOrder,
            _ => true,
          };
          final salesAt = _salesTimeForOrder(order).toUtc();
          final dateMatches =
              (fromUtc == null || !salesAt.isBefore(fromUtc)) &&
              (toUtc == null || salesAt.isBefore(toUtc));
          final searchMatches =
              query.isEmpty ||
              order.orderNumber.toLowerCase().contains(query) ||
              (order.customerName ?? '').toLowerCase().contains(query);
          return kindMatches && dateMatches && searchMatches;
        }).toList()..sort(
          (a, b) => _salesTimeForOrder(b).compareTo(_salesTimeForOrder(a)),
        );

    final safeOffset = offset.clamp(0, all.length);
    final safeLimit = limit.clamp(1, 100);
    final end = (safeOffset + safeLimit).clamp(safeOffset, all.length);
    final page = all.sublist(safeOffset, end);
    final refundAmounts = await _fetchRefundTotals(
      all.map((order) => order.id).toList(),
    );
    double netAmount(Order order) =>
        (order.totalAmount - (refundAmounts[order.id] ?? 0))
            .clamp(0, double.infinity)
            .toDouble();
    final names = await fetchCashierNames(
      page.map((order) => order.createdBy).whereType<String>().toSet().toList(),
    );
    final netAmounts = <String, double>{
      for (final order in page) order.id: netAmount(order),
    };
    final salesAt = <String, DateTime>{
      for (final order in page) order.id: _salesTimeForOrder(order),
    };
    final days = <String, SalesDaySummary>{};
    for (final order in all) {
      final date = _salesTimeForOrder(order).toLocal();
      final key =
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
      final previous = days[key];
      days[key] = SalesDaySummary(
        total: (previous?.total ?? 0) + netAmount(order),
        count: (previous?.count ?? 0) + 1,
      );
    }
    final total = all.fold<double>(0, (sum, order) => sum + netAmount(order));
    return SalesPageResult(
      orders: page,
      cashiers: names,
      netAmounts: netAmounts,
      salesAt: salesAt,
      totalSales: total,
      totalTransactions: all.length,
      averageSales: all.isEmpty ? 0 : total / all.length,
      hasMore: end < all.length,
      days: days,
    );
  }

  DateTime _salesTimeForOrder(Order order) {
    final paidAt =
        (order.payments ?? const <Payment>[])
            .map((payment) => payment.paidAt)
            .where((date) => date.millisecondsSinceEpoch > 0)
            .toList()
          ..sort();
    return paidAt.isEmpty ? order.createdAt : paidAt.last;
  }

  Future<Map<String, double>> _fetchRefundTotals(List<String> orderIds) async {
    if (orderIds.isEmpty) return const {};

    // Batasi panjang URL PostgREST pada outlet dengan riwayat besar. Jalur ini
    // hanya dipakai sementara ketika RPC pagination belum tersedia di server.
    final totals = <String, double>{};
    const chunkSize = 100;
    for (var start = 0; start < orderIds.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, orderIds.length);
      final rows = await _client
          .from('refunds')
          .select('order_id, amount')
          .inFilter('order_id', orderIds.sublist(start, end));
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final orderId = row['order_id'] as String?;
        if (orderId == null) continue;
        totals[orderId] =
            (totals[orderId] ?? 0) + ((row['amount'] as num?)?.toDouble() ?? 0);
      }
    }
    return totals;
  }

  /// Map id kasir → nama, untuk kolom "Kasir" di Penjualan.
  Future<Map<String, String>> fetchCashierNames(List<String> ids) async {
    if (ids.isEmpty) return {};
    final data = await _client
        .from('profiles')
        .select('id, full_name')
        .inFilter('id', ids);
    return {
      for (final r in (data as List))
        r['id'] as String: (r['full_name'] as String?) ?? '-',
    };
  }

  Future<void> updateOrderStatus(String orderId, OrderStatus status) async {
    await _client.rpc(
      'advance_order_status',
      params: {'p_order_id': orderId, 'p_status': status.value},
    );
  }

  /// Item order yang bisa direfund (qty tersisa = quantity − refunded_qty).
  Future<List<Map<String, dynamic>>> fetchRefundableItems(
    String orderId,
  ) async {
    final key = 'refundable_items_$orderId';
    if (!ConnectivityService.instance.online.value) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
    }
    try {
      final data = await _client
          .from('order_items')
          .select('id, quantity, refunded_qty, unit_price, menu_items(name)')
          .eq('order_id', orderId);
      final items = (data as List)
          .map((r) {
            final m = Map<String, dynamic>.from(r as Map);
            final mi = m['menu_items'];
            return {
              'id': m['id'],
              'name': (mi is Map ? mi['name'] : null) ?? 'Item',
              'quantity': (m['quantity'] as num?)?.toInt() ?? 0,
              'refunded_qty': (m['refunded_qty'] as num?)?.toInt() ?? 0,
              'unit_price': (m['unit_price'] as num?)?.toDouble() ?? 0,
            };
          })
          // Item yang seluruh jumlahnya sudah direfund tidak boleh ditawarkan
          // lagi. Server tetap menjadi pengaman terakhir terhadap refund ganda.
          .where(
            (item) => (item['quantity'] as int) > (item['refunded_qty'] as int),
          )
          .toList();
      await _offlineCache?.put(key, jsonEncode(items));
      return items;
    } catch (_) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Item order belum lunas yang dapat dibatalkan sebagian.
  Future<List<Map<String, dynamic>>> fetchVoidableItems(String orderId) async {
    final key = 'voidable_items_$orderId';
    if (!ConnectivityService.instance.online.value) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
    }
    try {
      final data = await _client
          .from('order_items')
          .select('id, quantity, unit_price, menu_items(name)')
          .eq('order_id', orderId);
      final items = (data as List)
          .map((r) {
            final m = Map<String, dynamic>.from(r as Map);
            final mi = m['menu_items'];
            return {
              'id': m['id'],
              'name': (mi is Map ? mi['name'] : null) ?? 'Item',
              'quantity': (m['quantity'] as num?)?.toInt() ?? 0,
              'unit_price': (m['unit_price'] as num?)?.toDouble() ?? 0,
            };
          })
          .where((item) => (item['quantity'] as int) > 0)
          .toList();
      await _offlineCache?.put(key, jsonEncode(items));
      return items;
    } catch (_) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Void sebagian item pada order belum lunas. Server mengurus persetujuan
  /// PIN, pemulihan stok, hitung ulang total, dan audit secara atomik.
  Future<Map<String, dynamic>> voidOrderItems(
    String orderId, {
    required List<Map<String, dynamic>> items,
    required String reason,
    required String approverPin,
    required String approverId,
  }) async {
    final res = await _client.rpc(
      'void_order_items',
      params: {
        'p_order': orderId,
        'p_items': items,
        'p_reason': reason,
        'p_approver_pin': approverPin,
        'p_approver_id': approverId,
      },
    );
    return Map<String, dynamic>.from(res as Map);
  }

  /// Refund sebagian: kirim daftar {order_item_id, qty} + alasan + PIN approver.
  /// Order tetap 'paid', stok tidak dikembalikan. Mengembalikan nama penyetuju.
  Future<String?> refundOrderItems(
    String orderId, {
    required List<Map<String, dynamic>> items,
    String? reason,
    required String approverPin,
    String? approverId,
  }) async {
    final res = await _client.rpc(
      'refund_order_items',
      params: {
        'p_order': orderId,
        'p_items': items,
        'p_reason': reason,
        'p_approver_pin': approverPin,
        'p_approver_id': approverId,
      },
    );
    if (res is Map) return res['approver'] as String?;
    return null;
  }

  /// Meja aktif di outlet (untuk picker pindah meja).
  Future<List<Map<String, dynamic>>> fetchTables(String outletId) async {
    final key = 'tables_$outletId';
    if (!ConnectivityService.instance.online.value) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
    }
    try {
      final data = await _client
          .from('restaurant_tables')
          .select(
            'id, outlet_id, table_number, area, capacity, status, is_active',
          )
          .eq('outlet_id', outletId)
          .eq('is_active', true)
          .order('table_number');
      await _offlineCache?.put(key, jsonEncode(data));
      return (data as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    } catch (_) {
      final cached = _cachedMaps(key);
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Perbarui snapshot status meja saat transaksi dibuat lokal. Ini hanya
  /// memengaruhi UI perangkat; trigger database tetap sumber kebenaran setelah
  /// outbox tersinkron.
  Future<void> setCachedTableStatus({
    required String outletId,
    required String? tableId,
    required String status,
  }) async {
    if (tableId == null || tableId.isEmpty) return;
    final key = 'tables_$outletId';
    final tables = _cachedMaps(key);
    if (tables == null) return;
    var changed = false;
    for (final table in tables) {
      if (table['id'] == tableId && table['status'] != status) {
        table['status'] = status;
        changed = true;
      }
    }
    if (changed) await _offlineCache?.put(key, jsonEncode(tables));
  }

  /// Masukkan order outbox ke snapshot Daftar Order. Dengan ini order tetap
  /// terlihat setelah pindah halaman atau restart sebelum server kembali.
  Future<void> cacheQueuedOrder(Map<String, dynamic> payload) async {
    final cache = _offlineCache;
    final row = _queuedOrderMap(payload);
    final outletId = payload['outletId'] as String?;
    final orderId = payload['clientOrderId'] as String?;
    if (cache == null || row == null || outletId == null || orderId == null) {
      return;
    }
    final paid = payload['kind'] == 'paid';
    final targetKey = paid
        ? 'orders_completed_$outletId'
        : 'orders_active_$outletId';
    final otherKey = paid
        ? 'orders_active_$outletId'
        : 'orders_completed_$outletId';
    final target = _cachedMaps(targetKey) ?? <Map<String, dynamic>>[];
    final other = _cachedMaps(otherKey) ?? <Map<String, dynamic>>[];
    target.removeWhere((entry) => entry['id'] == orderId);
    other.removeWhere((entry) => entry['id'] == orderId);
    target.insert(0, row);
    await cache.put(targetKey, jsonEncode(target));
    await cache.put(otherKey, jsonEncode(other));
  }

  /// Terapkan pembayaran ke snapshot order lokal segera setelah transaksi
  /// masuk jurnal offline. [paymentId] juga menjadi kunci idempoten agar retry
  /// tombol atau restart aplikasi tidak menggandakan nominal pembayaran.
  ///
  /// Order yang lunas dipindahkan dari daftar aktif ke daftar selesai. Server
  /// tetap menjadi sumber kebenaran dan akan mengganti snapshot ini setelah
  /// jurnal berhasil tersinkron.
  Future<void> applyCachedPayment({
    required String outletId,
    required String orderId,
    required String paymentId,
    required PaymentMethod method,
    required double amount,
    required String paidAt,
    required bool finalize,
  }) async {
    final cache = _offlineCache;
    if (cache == null) return;
    final activeKey = 'orders_active_$outletId';
    final completedKey = 'orders_completed_$outletId';
    final active = _cachedMaps(activeKey) ?? <Map<String, dynamic>>[];
    final completed = _cachedMaps(completedKey) ?? <Map<String, dynamic>>[];

    Map<String, dynamic>? row;
    final activeIndex = active.indexWhere((entry) => entry['id'] == orderId);
    final completedIndex = completed.indexWhere(
      (entry) => entry['id'] == orderId,
    );
    if (activeIndex >= 0) {
      row = active[activeIndex];
    } else if (completedIndex >= 0) {
      row = completed[completedIndex];
    }
    if (row == null) return;

    final payments = (row['payments'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    if (!payments.any((entry) => entry['id'] == paymentId)) {
      payments.add({
        'id': paymentId,
        'order_id': orderId,
        'outlet_id': outletId,
        'method': method.value,
        'amount': amount,
        'reference_number': null,
        'paid_at': paidAt,
      });
    }
    row['payments'] = payments;
    row['updated_at'] = paidAt;

    final total = (row['total_amount'] as num?)?.toDouble() ?? 0;
    final paidTotal = payments.fold<double>(
      0,
      (sum, payment) => sum + ((payment['amount'] as num?)?.toDouble() ?? 0),
    );
    final isPaid = finalize || paidTotal >= total - 0.01;
    if (isPaid) {
      row['status'] = 'paid';
      if (activeIndex >= 0) active.removeAt(activeIndex);
      if (completedIndex >= 0) completed.removeAt(completedIndex);
      completed.insert(0, row);
    } else if (activeIndex < 0) {
      // Snapshot lama bisa berada pada daftar selesai karena perubahan lokal
      // sebelumnya. Pembayaran parsial harus tetap tampil sebagai order aktif.
      completed.removeWhere((entry) => entry['id'] == orderId);
      active.insert(0, row);
    }

    await cache.put(activeKey, jsonEncode(active));
    await cache.put(completedKey, jsonEncode(completed));
  }

  /// Pindahkan order ke meja lain. Trigger sync_table_status membebaskan meja
  /// lama & menempati meja baru secara otomatis.
  Future<void> transferTable(String orderId, String? newTableId) async {
    await _client.rpc(
      'transfer_order_table',
      params: {'p_order_id': orderId, 'p_table_id': newTableId},
    );
  }

  /// Gabungkan order [sourceId] ke [targetId] (item + stok pindah, sumber void).
  Future<void> mergeOrders(String sourceId, String targetId) async {
    await _client.rpc(
      'merge_orders',
      params: {'p_source': sourceId, 'p_target': targetId},
    );
  }

  /// Hapus draf lama setelah order penggantinya berhasil dibuat.
  ///
  /// Guard status sengaja dipasang di client query sebagai lapisan tambahan:
  /// order yang sudah confirmed/paid tidak boleh hilang lewat alur recall.
  /// order_items & order_item_options ikut terhapus via ON DELETE CASCADE.
  Future<void> deleteOrder(String orderId) async {
    await _client
        .from('orders')
        .delete()
        .eq('id', orderId)
        .eq('status', 'draft');
  }

  /// Ambil extras tiap order_item, dikelompokkan per `order_item_id`.
  Future<Map<String, List<Map<String, dynamic>>>> fetchOrderItemOptions(
    List<String> orderItemIds,
  ) async {
    if (orderItemIds.isEmpty) return {};
    final data = await _client
        .from('order_item_options')
        .select()
        .inFilter('order_item_id', orderItemIds);
    final result = <String, List<Map<String, dynamic>>>{};
    for (final row in (data as List).cast<Map<String, dynamic>>()) {
      final itemId = row['order_item_id'] as String;
      (result[itemId] ??= []).add(row);
    }
    return result;
  }

  Future<void> processPayment({
    required String orderId,
    required String outletId,
    required PaymentMethod method,
    required double amount,
    String? idempotencyKey,
    String? tillShiftId, // till penerima kas (di-resolve UI utk bayar tunai)
    String? expectedUserId,
    String? paidAt,
  }) async {
    // UI clock-in dan Supabase harus menunjuk staf yang sama. Bila pergantian
    // sesi PIN belum tuntas, jangan mengirim pembayaran dengan token akun
    // perangkat karena server memang wajib menolaknya.
    if (expectedUserId != null &&
        _client.auth.currentUser?.id != expectedUserId) {
      throw StateError(
        'Sesi pembayaran tidak sesuai dengan pengguna yang sedang masuk',
      );
    }
    final key = idempotencyKey ?? _uuid.v4();
    if (tillShiftId == null) {
      throw StateError(
        'Pembayaran wajib dihubungkan ke shift kasir yang sedang aktif',
      );
    }

    // Atribusi shift + payment diproses oleh SATU RPC agar kegagalan pembayaran
    // tidak meninggalkan order yang sudah terlanjur berpindah shift.
    await _withTransportFallback(
      (client) => client.rpc(
        'record_pos_payment_with_context',
        params: {
          'p_order_id': orderId,
          'p_outlet_id': outletId,
          'p_shift_id': tillShiftId,
          'p_force_order_shift': method == PaymentMethod.cash,
          'p_method': method.value,
          'p_amount': amount,
          'p_reference_number': null,
          'p_idempotency_key': key,
          'p_finalize': true,
          'p_paid_at': ?paidAt,
        },
      ),
    );

    // Earn poin loyalty bila order terhubung ke member (idempoten per order via
    // RPC). Non-fatal: kegagalan loyalty tidak boleh menggagalkan pembayaran.
    try {
      final row = await _client
          .from('orders')
          .select('loyalty_member_id')
          .eq('id', orderId)
          .maybeSingle();
      final memberId = row?['loyalty_member_id'] as String?;
      if (memberId != null) {
        await _client.rpc(
          'award_loyalty_points',
          params: {'p_order_id': orderId, 'p_member_id': memberId},
        );
      }
    } catch (_) {
      // non-fatal
    }
  }

  // ── Split bill / bagi tagihan ───────────────────────────────────────────────
  /// Total yang sudah dibayar untuk satu order (jumlah semua baris payments).
  Future<double> fetchPaidTotal(String orderId) async {
    final rows = await _withTransportFallback(
      (client) =>
          client.from('payments').select('amount').eq('order_id', orderId),
    );
    return (rows as List).fold<double>(
      0,
      (s, r) => s + ((r['amount'] as num?)?.toDouble() ?? 0),
    );
  }

  /// Snapshot atomik yang dipakai tepat sebelum membayar order yang sudah ada.
  ///
  /// Total order dan payments wajib dibaca dalam satu response agar dialog
  /// pembayaran tidak mengirim nominal lama setelah item diubah/di-void atau
  /// setelah perangkat lain mencatat pembayaran.
  Future<OrderPaymentSnapshot> fetchPaymentSnapshot(String orderId) async {
    final row = await _withTransportFallback(
      (client) => client
          .from('orders')
          .select('total_amount, status, payments(amount)')
          .eq('id', orderId)
          .single(),
    );
    final payments = (row['payments'] as List?) ?? const [];
    final paidTotal = payments.fold<double>(
      0,
      (sum, payment) =>
          sum + ((payment as Map?)?['amount'] as num? ?? 0).toDouble(),
    );
    return OrderPaymentSnapshot(
      totalAmount: ((row['total_amount'] as num?) ?? 0).toDouble(),
      paidTotal: paidTotal,
      status: row['status']?.toString() ?? '',
    );
  }

  /// Catat satu pembayaran split. Pembayaran terakhir dapat sekaligus
  /// memfinalisasi order secara atomik di server.
  Future<void> addSplitPayment({
    required String orderId,
    required String outletId,
    required String shiftId,
    required PaymentMethod method,
    required double amount,
    bool finalize = false,
    String? idempotencyKey,
    String? paidAt,
  }) async {
    final key = idempotencyKey ?? _uuid.v4();
    await _withTransportFallback(
      (client) => client.rpc(
        'record_pos_payment_with_context',
        params: {
          'p_order_id': orderId,
          'p_outlet_id': outletId,
          'p_shift_id': shiftId,
          'p_force_order_shift': method == PaymentMethod.cash,
          'p_method': method.value,
          'p_amount': amount,
          'p_reference_number': null,
          'p_idempotency_key': key,
          'p_finalize': finalize,
          'p_paid_at': ?paidAt,
        },
      ),
    );
  }

  /// Finalisasi setelah total pembayaran menutupi tagihan → naikkan status.
  /// Selesaikan bagi tagihan. Server yang memutuskan lunas — ia menolak bila
  /// jumlah `payments` belum menutupi total. Dulu klien langsung menyetel
  /// status='paid', sehingga bug klien / panggilan API langsung bisa melunasi
  /// order tanpa uang masuk.
  Future<void> finalizeSplitPayment(String orderId) async {
    await _withTransportFallback(
      (client) =>
          client.rpc('finalize_split_payment', params: {'p_order_id': orderId}),
    );
  }

  /// Wi-Fi publik kadang mengizinkan request ringan tetapi memutus POST RPC
  /// Supabase. Untuk operasi pembayaran yang idempoten, ulangi sekali melalui
  /// gateway publik dengan access token sesi yang sama.
  Future<T> _withTransportFallback<T>(
    Future<T> Function(SupabaseClient client) operation,
  ) async {
    try {
      return await operation(_client);
    } catch (error) {
      // Host failover hanya untuk kegagalan koneksi murni. Error PostgREST
      // sementara (mis. PGRST002) harus kembali ke pemanggil agar transaksi
      // tetap berada di jurnal dan dicoba ulang, bukan dikirim ke host lain.
      if (!backend.isBackendTransportFailure(error)) rethrow;

      final injected = _injectedFallbackClient;
      final alternate = injected ?? _createAlternateClient();
      if (alternate == null) rethrow;
      try {
        return await operation(alternate);
      } finally {
        // Jangan menahan dialog pembayaran hanya untuk cleanup client sementara
        // (dispose realtime dapat menunggu beberapa detik pada Wi-Fi buruk).
        if (injected == null) {
          unawaited(alternate.dispose().catchError((_) {}));
        }
      }
    }
  }

  SupabaseClient? _createAlternateClient() {
    final active = _normalizeUrl(AppConfig.activeSupabaseUrl);
    final primary = _normalizeUrl(AppConfig.supabaseUrl);
    final fallback = _normalizeUrl(AppConfig.supabaseFallbackUrl);
    final alternate = active == fallback ? primary : fallback;
    if (alternate.isEmpty || alternate == active) return null;

    return SupabaseClient(
      alternate,
      AppConfig.supabaseAnonKey,
      accessToken: () async {
        try {
          return _client.auth.currentSession?.accessToken;
        } catch (_) {
          return null;
        }
      },
    );
  }

  static String _normalizeUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  /// Void order dengan persetujuan PIN atasan (Manajer/Owner/Admin).
  /// Verifikasi + update dilakukan atomik di RPC; mengembalikan nama penyetuju.
  /// voided_by = pelaku (auth.uid), approved_by = penyetuju (di-set RPC).
  Future<String?> voidOrder(
    String orderId, {
    String? reason,
    required String approverPin,
    String? approverId,
  }) async {
    final rows = await _client.rpc(
      'void_order_with_approval',
      params: {
        'p_order': orderId,
        'p_reason': reason,
        'p_approver_pin': approverPin,
        'p_approver_id': ?approverId,
      },
    );
    final list = (rows as List?) ?? const [];
    return list.isNotEmpty
        ? (list.first as Map)['approver_name'] as String?
        : null;
  }

  /// Refund order dengan persetujuan PIN atasan (Manajer/Owner/Admin).
  Future<String?> refundOrder(
    String orderId, {
    String? reason,
    required String approverPin,
    String? approverId,
  }) async {
    final rows = await _client.rpc(
      'refund_order_with_approval',
      params: {
        'p_order': orderId,
        'p_reason': reason,
        'p_approver_pin': approverPin,
        'p_approver_id': ?approverId,
      },
    );
    final list = (rows as List?) ?? const [];
    return list.isNotEmpty
        ? (list.first as Map)['approver_name'] as String?
        : null;
  }

  // ── PIN hak akses (migration 047) ───────────────────────────────────────────
  // Catatan: PIN HANYA diatur oleh owner via owner panel (admin_set_user_pin).
  // Mobile hanya verifikasi & cek keberadaan PIN — tidak bisa set sendiri.
  Future<bool> verifyPin(String pin) async {
    final ok = await _client.rpc('verify_my_pin', params: {'p_pin': pin});
    return ok == true;
  }

  Future<bool> hasPin() async {
    final has = await _client.rpc('has_my_pin');
    return has == true;
  }

  /// Feed Broadcast bersama untuk notifikasi, badge, dan daftar order. Trigger
  /// database mengirim sinyal hanya saat order berubah; service mengambil satu
  /// snapshot 200 baris lalu membaginya ke semua konsumen perangkat.
  Stream<List<Map<String, dynamic>>> watchOrders(String outletId) {
    return OrderRealtimeService.instance.watch(outletId);
  }
}

/// Hanya kegagalan transport yang aman dialihkan. Penolakan PostgreSQL/RLS
/// tetap diteruskan apa adanya agar tidak disamarkan sebagai masalah jaringan.
bool isBackendTransportFailure(Object error) {
  return backend.isBackendTemporarilyUnavailable(error);
}

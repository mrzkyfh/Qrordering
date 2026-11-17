import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';
import 'package:qrordering/shared/models/enums.dart';

/// Regression replay untuk jalur offline. Sejak migration 141, header, item,
/// extra, dan komponen finansial dikirim ke satu RPC atomik; test ini sengaja
/// memastikan tidak ada lagi insert REST per tabel yang bisa meninggalkan order
/// setengah jadi.
class _FakePostgrest {
  final List<({String method, String path, dynamic body})> requests = [];
  late final HttpServer _server;
  String paymentStatus = 'paid';
  num paidTotal = 24000;
  num orderTotal = 24000;

  String get url => 'http://127.0.0.1:${_server.port}';

  bool called(String rpc) => requests.any((r) => r.path == '/rest/v1/rpc/$rpc');

  Map<String, dynamic> rpcArgs(String rpc) =>
      (requests.firstWhere((r) => r.path == '/rest/v1/rpc/$rpc').body as Map)
          .cast<String, dynamic>();

  List<Map<String, dynamic>> rpcCalls(String rpc) => requests
      .where((request) => request.path == '/rest/v1/rpc/$rpc')
      .map((request) => (request.body as Map).cast<String, dynamic>())
      .toList();

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      requests.add((
        method: req.method,
        path: req.uri.path,
        body: raw.isEmpty ? null : jsonDecode(raw),
      ));
      final res = req.response..headers.contentType = ContentType.json;
      res.write(jsonEncode(_reply(req)));
      await res.close();
    });
  }

  dynamic _reply(HttpRequest req) {
    final p = req.uri.path;
    if (p == '/rest/v1/rpc/create_pos_order') {
      final args = requests.last.body as Map;
      return {
        'order_id': args['p_order_id'] ?? 'order-created-1',
        'order_number': '001',
        'total_amount': args['p_loyalty_discount'] == null
            ? 24000
            : 24000 - (args['p_loyalty_discount'] as num),
      };
    }
    if (p == '/rest/v1/rpc/record_pos_payment_with_context') {
      return {
        'payment_id': 'payment-1',
        'paid_total': paidTotal,
        'order_total': orderTotal,
        'status': paymentStatus,
      };
    }
    if (p == '/rest/v1/rpc/finalize_split_payment') {
      return {
        'paid_total': paidTotal,
        'order_total': orderTotal,
        'status': paymentStatus,
      };
    }
    if (p == '/rest/v1/rpc/award_loyalty_points') return 12;
    // Cleanup replaced drafts boleh memakai DELETE scoped ke outlet/status.
    return req.method == 'GET' ? [] : {};
  }

  Future<void> stop() => _server.close(force: true);
}

Map<String, dynamic> _payload({
  String? shiftId = 'shift-andi',
  String? loyaltyMemberId,
  int redeemedPoints = 0,
  double loyaltyDiscount = 0,
  String? promoId,
  String? voucherId,
  bool taxInclusive = false,
}) => {
  'kind': 'paid',
  'clientOrderId': '11111111-1111-4111-8111-111111111111',
  'localReceiptNo': 'A7-014',
  'outletId': 'outlet-1',
  'createdBy': 'kasir-1',
  'orderType': 'dine_in',
  'tableId': 'table-9',
  'customerName': 'Budi',
  'subtotal': 24000,
  'discountAmount': 0,
  'taxAmount': 0,
  'serviceCharge': 0,
  'total': 24000 - loyaltyDiscount,
  'paymentMethod': 'cash',
  'amount': 24000 - loyaltyDiscount,
  'idempotencyKey': '22222222-2222-4222-8222-222222222222',
  'shiftId': shiftId,
  'loyaltyMemberId': loyaltyMemberId,
  'loyaltyDiscount': loyaltyDiscount,
  'redeemedPoints': redeemedPoints,
  'promoId': promoId,
  'voucherId': voucherId,
  'taxInclusive': taxInclusive,
  'createdAt': '2026-07-16T03:04:05.000Z',
  'items': [
    {
      'menuItemId': 'menu-1',
      'name': 'Kopi',
      'quantity': 2,
      'unitPrice': 12000,
      'subtotal': 24000,
      'notes': 'less sugar',
      'extras': [
        {
          'menuExtraId': 'ex-1',
          'menuExtraOptionId': 'exo-1',
          'extraName': 'Topping',
          'optionName': 'Boba',
          'price': 2000,
        },
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakePostgrest api;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    api = _FakePostgrest();
    await api.start();
    await Supabase.initialize(
      url: api.url,
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await api.stop();
  });

  test('replay memakai satu RPC atomik dengan data lengkap', () async {
    await PosDatasource().pushOfflineOrder(
      _payload(
        loyaltyMemberId: 'member-7',
        redeemedPoints: 50,
        loyaltyDiscount: 5000,
        promoId: 'promo-3',
        voucherId: 'voucher-2',
      ),
    );

    expect(api.called('create_pos_order'), isTrue);
    final args = api.rpcArgs('create_pos_order');
    expect(args['p_order_id'], '11111111-1111-4111-8111-111111111111');
    expect(args['p_shift_id'], 'shift-andi');
    expect(args['p_created_by'], 'kasir-1');
    expect(args['p_loyalty_member_id'], 'member-7');
    expect(args['p_redeemed_points'], 50);
    expect(args['p_loyalty_discount'], 5000);
    expect(args['p_promo_id'], 'promo-3');
    expect(args['p_voucher_id'], 'voucher-2');
    expect(args['p_local_receipt_no'], 'A7-014');
    expect(args.containsKey('p_total_amount'), isFalse);

    final items = (args['p_items'] as List).cast<Map>();
    expect(items.single['menu_item_id'], 'menu-1');
    expect(items.single['quantity'], 2);
    expect(items.single['unit_price'], 12000);
    expect(items.single['notes'], 'less sugar');
    expect(
      (items.single['extras'] as List).single['menu_extra_option_id'],
      'exo-1',
    );

    // Promo/redeem sekarang diklaim oleh payment RPC di server dalam
    // transaksi yang sama, bukan RPC tambahan dari client setelah paid.
    expect(api.called('apply_promo_usage'), isFalse);
    expect(api.called('redeem_loyalty_points'), isFalse);
    expect(api.called('record_pos_payment_with_context'), isTrue);
    expect(api.called('award_loyalty_points'), isTrue);
  });

  test(
    'pembayaran mempertahankan idempotency dan waktu transaksi asli',
    () async {
      await PosDatasource().pushOfflineOrder(_payload());
      final pay = api.rpcArgs('record_pos_payment_with_context');
      expect(pay['p_idempotency_key'], '22222222-2222-4222-8222-222222222222');
      expect(pay['p_paid_at'], '2026-07-16T03:04:05.000Z');
      expect(pay['p_method'], 'cash');
      expect(pay['p_shift_id'], 'shift-andi');
      expect(pay['p_force_order_shift'], isTrue);
      expect(pay['p_amount'], 24000);
      expect(pay['p_finalize'], isTrue);
    },
  );

  test(
    'split offline mereplay semua metode lalu finalisasi satu kali',
    () async {
      final payload = _payload()
        ..['payments'] = [
          {'method': 'cash', 'amount': 10000, 'idempotencyKey': 'split-cash-1'},
          {'method': 'qris', 'amount': 14000, 'idempotencyKey': 'split-qris-1'},
        ];

      await PosDatasource().pushOfflineOrder(payload);

      final calls = api.rpcCalls('record_pos_payment_with_context');
      expect(calls, hasLength(2));
      expect(calls.map((call) => call['p_method']), ['cash', 'qris']);
      expect(calls.map((call) => call['p_amount']), [10000, 14000]);
      expect(calls.every((call) => call['p_finalize'] == false), isTrue);
      expect(calls[0]['p_force_order_shift'], isTrue);
      expect(calls[1]['p_force_order_shift'], isFalse);
      expect(api.called('finalize_split_payment'), isTrue);
      expect(
        api.rpcArgs('finalize_split_payment')['p_order_id'],
        payload['clientOrderId'],
      );
    },
  );

  test(
    'replay tidak dianggap sukses bila pembayaran belum melunasi total server',
    () async {
      api.paymentStatus = 'confirmed';
      api.paidTotal = 24000;
      api.orderTotal = 25000;

      await expectLater(
        PosDatasource().pushOfflineOrder(_payload()),
        throwsA(
          isA<PostgrestException>()
              .having((e) => e.code, 'code', '22023')
              .having(
                (e) => e.message,
                'message',
                contains('belum melunasi total resmi server'),
              ),
        ),
      );
    },
  );

  test('draft tidak membuat pembayaran', () async {
    await PosDatasource().pushOfflineOrder(_payload()..['kind'] = 'draft');
    expect(api.called('record_pos_payment_with_context'), isFalse);
    expect(
      api.requests.any(
        (r) => r.method == 'POST' && r.path == '/rest/v1/orders',
      ),
      isFalse,
    );
  });

  test('createOrder memakai RPC atomik dan snapshot pajak', () async {
    await PosDatasource().createOrder(
      outletId: 'outlet-1',
      cart: const [],
      orderType: OrderType.dineIn,
      createdBy: 'kasir-1',
      discountAmount: 5000,
      taxAmount: 10000,
      serviceCharge: 2000,
      taxInclusive: true,
      promoId: 'promo-1',
      voucherId: 'voucher-1',
    );

    final args = api.rpcArgs('create_pos_order');
    expect(args['p_tax_inclusive'], isTrue);
    expect(args['p_discount_amount'], 5000);
    expect(args['p_tax_amount'], 10000);
    expect(args['p_service_charge'], 2000);
    expect(args['p_promo_id'], 'promo-1');
    expect(args['p_voucher_id'], 'voucher-1');
    expect(args.containsKey('p_total_amount'), isFalse);
  });

  test(
    'split bill memakai total resmi server, bukan total cache perangkat',
    () async {
      final result = await PosDatasource().createOrderWithServerTotal(
        outletId: 'outlet-1',
        cart: const [],
        orderType: OrderType.dineIn,
        createdBy: 'kasir-1',
        // Simulasikan cache perangkat yang masih menghitung Rp23.000,
        // sedangkan server mengembalikan total terbaru Rp24.000.
        taxAmount: 1000,
      );

      expect(result.orderId, 'order-created-1');
      expect(result.orderNumber, '001');
      expect(
        result.totalAmount,
        24000,
        reason:
            'nominal pembagi/finalisasi harus mengikuti kalkulasi server agar '
            'tidak ditolak ketika cache pajak atau layanan tertinggal',
      );
    },
  );
}

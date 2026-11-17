import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:time420s/features/orders/data/datasources/orders_datasource.dart';
import 'package:time420s/shared/models/enums.dart';

/// Regression: "Selesaikan Pembayaran" pada bagi tagihan WAJIB lewat RPC
/// finalize_split_payment (117), bukan `UPDATE orders SET status='paid'`.
///
/// Dulu klien yang memutuskan lunas — satu-satunya penjaga "sisa harus nol"
/// ada di layar (`_remaining <= 0`). Bug klien, race, atau panggilan API
/// langsung bisa melunasi order tanpa satu rupiah pun masuk, dan tak ada jejak
/// mencurigakan karena statusnya sah. Server kini yang memeriksa uangnya.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<({String method, String path, dynamic body})> requests;

  setUp(() async {
    // flutter_test memasang HttpOverrides yang memblokir jaringan nyata.
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});

    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      requests.add((
        method: req.method,
        path: req.uri.path,
        body: raw.isEmpty ? null : jsonDecode(raw),
      ));
      final res = req.response..headers.contentType = ContentType.json;
      if (req.uri.path == '/rest/v1/orders') {
        res.write(
          jsonEncode({
            'status': 'confirmed',
            'total_amount': 122100,
            'payments': [
              {'amount': 22100},
              {'amount': 10000},
            ],
          }),
        );
      } else {
        res.write(jsonEncode({'status': 'paid'}));
      }
      await res.close();
    });

    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await server.close(force: true);
  });

  test('memanggil RPC finalize_split_payment dengan order id', () async {
    await OrdersDatasource().finalizeSplitPayment('order-9');

    final rpc = requests.singleWhere(
      (r) => r.path == '/rest/v1/rpc/finalize_split_payment',
      orElse: () =>
          throw TestFailure('RPC finalize_split_payment tidak dipanggil'),
    );
    expect(rpc.method, 'POST');
    expect((rpc.body as Map)['p_order_id'], 'order-9');
  });

  test(
    'snapshot pembayaran membaca total dan seluruh pembayaran sekaligus',
    () async {
      final snapshot = await OrdersDatasource().fetchPaymentSnapshot('order-9');

      expect(snapshot.totalAmount, 122100);
      expect(snapshot.paidTotal, 32100);
      expect(snapshot.remaining, 90000);
      expect(snapshot.status, 'confirmed');

      final request = requests.singleWhere(
        (r) => r.path == '/rest/v1/orders',
        orElse: () => throw TestFailure('Snapshot order tidak diminta'),
      );
      expect(request.method, 'GET');
    },
  );

  test('TIDAK menyetel status=paid sendiri lewat PATCH', () async {
    await OrdersDatasource().finalizeSplitPayment('order-9');

    final patches = requests.where((r) => r.method == 'PATCH').toList();
    expect(
      patches,
      isEmpty,
      reason:
          'klien tidak boleh lagi memutuskan lunas — hanya server yang '
          'boleh, setelah memastikan pembayaran menutupi total',
    );
  });

  test('split payment mencatat shift dan uang dalam satu RPC atomik', () async {
    await OrdersDatasource().addSplitPayment(
      orderId: 'order-9',
      outletId: 'outlet-1',
      shiftId: 'shift-kasir-1',
      method: PaymentMethod.qris,
      amount: 25000,
    );

    final rpc = requests.singleWhere(
      (r) => r.path == '/rest/v1/rpc/record_pos_payment_with_context',
      orElse: () => throw TestFailure(
        'RPC record_pos_payment_with_context tidak dipanggil',
      ),
    );
    expect(rpc.body, {
      'p_order_id': 'order-9',
      'p_outlet_id': 'outlet-1',
      'p_shift_id': 'shift-kasir-1',
      'p_force_order_shift': false,
      'p_method': 'qris',
      'p_amount': 25000.0,
      'p_reference_number': null,
      'p_idempotency_key': isA<String>(),
      'p_finalize': false,
    });
    expect(
      requests.where(
        (r) => r.path == '/rest/v1/rpc/assign_order_payment_context',
      ),
      isEmpty,
    );
  });

  test('pembayaran split terakhir meminta finalisasi atomik', () async {
    await OrdersDatasource().addSplitPayment(
      orderId: 'order-9',
      outletId: 'outlet-1',
      shiftId: 'shift-kasir-1',
      method: PaymentMethod.cash,
      amount: 25000,
      finalize: true,
    );

    final rpc = requests.singleWhere(
      (r) => r.path == '/rest/v1/rpc/record_pos_payment_with_context',
    );
    expect((rpc.body as Map)['p_finalize'], isTrue);
  });

  test('waktu bayar asli ikut dikirim saat transaksi diputar ulang', () async {
    await OrdersDatasource().processPayment(
      orderId: 'order-offline-1',
      outletId: 'outlet-1',
      method: PaymentMethod.cash,
      amount: 56000,
      tillShiftId: 'shift-kasir-1',
      idempotencyKey: 'offline-payment-1',
      paidAt: '2026-07-30T06:07:08.000Z',
    );

    final rpc = requests.singleWhere(
      (r) => r.path == '/rest/v1/rpc/record_pos_payment_with_context',
    );
    expect((rpc.body as Map)['p_paid_at'], '2026-07-30T06:07:08.000Z');
  });

  test('pembayaran mencoba gateway saat jalur utama putus', () async {
    final unavailable = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final unavailablePort = unavailable.port;
    await unavailable.close(force: true);

    final direct = SupabaseClient(
      'http://127.0.0.1:$unavailablePort',
      'test-anon-key',
    );
    final fallback = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'test-anon-key',
    );
    try {
      await OrdersDatasource(
        client: direct,
        fallbackClient: fallback,
      ).processPayment(
        orderId: 'order-wifi-cafe',
        outletId: 'outlet-1',
        method: PaymentMethod.cash,
        amount: 56000,
        tillShiftId: 'shift-kasir-1',
        idempotencyKey: 'wifi-cafe-payment-1',
      );
    } finally {
      await direct.dispose();
      await fallback.dispose();
    }

    final rpc = requests.singleWhere(
      (r) => r.path == '/rest/v1/rpc/record_pos_payment_with_context',
    );
    expect((rpc.body as Map)['p_order_id'], 'order-wifi-cafe');
    expect((rpc.body as Map)['p_idempotency_key'], 'wifi-cafe-payment-1');
  });

  test('penolakan server diteruskan, tidak ditelan diam-diam', () async {
    // Server menolak: pembayaran belum menutupi total.
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await utf8.decoder.bind(req).join();
      final res = req.response
        ..statusCode = 400
        ..headers.contentType = ContentType.json;
      res.write(
        jsonEncode({
          'code': '22023',
          'message':
              'Pembayaran belum menutupi total (terbayar 40000 dari 100000)',
          'details': null,
        }),
      );
      await res.close();
    });
    await Supabase.instance.dispose();
    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );

    // Kasir HARUS melihat kegagalan ini — bukan dikira sukses.
    await expectLater(
      OrdersDatasource().finalizeSplitPayment('order-9'),
      throwsA(isA<PostgrestException>()),
    );
  });
}

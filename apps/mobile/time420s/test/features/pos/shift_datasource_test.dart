import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:time420s/features/pos/data/datasources/shift_datasource.dart';

class _FakeShiftApi {
  String? insertErrorCode;
  bool activeShiftAvailable = true;
  bool failRecentShifts = false;
  final requests = <({String method, String path, Uri uri, Object? body})>[];
  late final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty ? null : jsonDecode(raw);
      requests.add((
        method: request.method,
        path: request.uri.path,
        uri: request.uri,
        body: body,
      ));
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET' &&
          request.uri.path == '/rest/v1/shifts' &&
          request.uri.queryParameters['end_time'] == 'not.is.null' &&
          failRecentShifts) {
        request.response.statusCode = 503;
        request.response.write(
          jsonEncode({
            'message': 'PostgREST temporarily unavailable',
            'code': 'PGRST002',
            'details': '',
          }),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/rest/v1/shifts') {
        if (insertErrorCode != null) {
          request.response.statusCode = 409;
          request.response.write(
            jsonEncode({'code': insertErrorCode, 'message': 'insert rejected'}),
          );
        } else {
          request.response.statusCode = 201;
          request.response.write(
            jsonEncode({
              'id': 'new-shift',
              'outlet_id': 'outlet-1',
              'kasir_id': 'kasir-1',
              'start_time': '2026-09-04T06:46:02Z',
              'opening_cash': (body as Map)['opening_cash'],
            }),
          );
        }
        await request.response.close();
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/rest/v1/rpc/open_shift_idempotent' &&
          insertErrorCode != null) {
        request.response.statusCode = 409;
        request.response.write(
          jsonEncode({'code': insertErrorCode, 'message': 'insert rejected'}),
        );
        await request.response.close();
        return;
      }
      request.response.write(jsonEncode(_reply(request)));
      await request.response.close();
    });
  }

  Object _reply(HttpRequest request) {
    switch (request.uri.path) {
      case '/rest/v1/cash_movements':
        return [
          {
            'id': 'move-in',
            'shift_id': 'shift-1',
            'outlet_id': 'outlet-1',
            'type': 'in',
            'amount': 10000,
            'note': 'Modal tambahan',
            'created_by': 'kasir-1',
            'created_at': '2026-07-25T01:00:00.000Z',
          },
          {
            'id': 'move-out',
            'shift_id': 'shift-1',
            'outlet_id': 'outlet-1',
            'type': 'out',
            'amount': 2000,
            'note': 'Belanja es',
            'created_by': 'kasir-1',
            'created_at': '2026-07-25T02:00:00.000Z',
          },
        ];
      case '/rest/v1/shifts':
        if (!activeShiftAvailable) return [];
        return [
          {
            'id': 'shift-active',
            'outlet_id': 'outlet-1',
            'kasir_id': 'kasir-1',
            'start_time': '2026-07-25T01:00:00.000Z',
            'end_time': null,
            'opening_cash': 50000,
            'staff': {'full_name': 'Siti Kasir'},
          },
        ];
      case '/rest/v1/orders':
        return [
          {'id': 'order-1'},
          {'id': 'order-2'},
        ];
      case '/rest/v1/payments':
        return [
          {'amount': 60000},
          {'amount': 40000},
        ];
      case '/rest/v1/refunds':
        return [
          {'amount': 10000},
        ];
      case '/rest/v1/rpc/record_cash_movement_idempotent':
        return {
          'id': 'move-new',
          'shift_id': 'shift-1',
          'outlet_id': 'outlet-1',
          'type': 'out',
          'amount': 15000,
          'note': 'Belanja bahan',
          'created_by': 'kasir-1',
          'created_at': '2026-07-25T03:00:00.000Z',
        };
      case '/rest/v1/rpc/open_shift_idempotent':
        return {
          'id': 'new-shift',
          'outlet_id': 'outlet-1',
          'kasir_id': 'kasir-1',
          'start_time': '2026-09-04T06:46:02Z',
          'opening_cash': 125000,
        };
      case '/rest/v1/rpc/close_shift_idempotent_with_report':
        return {
          'shift_id': 'shift-1',
          'outlet_id': 'outlet-1',
          'outlet': {
            'name': 'Time 420s',
            'address': 'Bekasi',
            'phone': '',
            'city': 'Bekasi',
            'settings': <String, dynamic>{},
          },
          'cashier_id': 'kasir-1',
          'cashier_name': 'Kasir',
          'opened_at': '2026-07-25T01:00:00.000Z',
          'closed_at': '2026-07-25T10:00:00.000Z',
          'opening_cash': 50000,
          'closing_cash': 147500,
          'expected_cash': 148000,
          'cash_difference': -500,
          'cash_received': 90000,
          'non_cash_received': 0,
          'total_receipts': 90000,
          'tax_total': 0,
          'service_charge_total': 0,
          'discount_total': 0,
          'refund_total': 10000,
          'cash_in': 10000,
          'cash_out': 2000,
          'completed_transactions': 2,
          'unpaid_transactions': 0,
          'void_item_quantity': 0,
          'void_item_amount': 0,
          'product_quantity': 2,
          'payment_methods': [
            {'method': 'cash', 'amount': 90000},
          ],
          'products': [
            {'name': 'Kebab', 'quantity': 2, 'amount': 90000},
          ],
          'expenses': [
            {
              'id': 'move-out',
              'category': 'operasional',
              'description': 'Belanja es',
              'amount': 2000,
              'created_at': '2026-07-25T02:00:00.000Z',
            },
          ],
          'notes': 'Selisih lima ratus',
        };
      default:
        return [];
    }
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
  late _FakeShiftApi api;
  late ShiftDatasource datasource;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    api = _FakeShiftApi();
    await api.start();
    await Supabase.initialize(
      url: api.url,
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
    datasource = ShiftDatasource();
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await api.stop();
  });

  test(
    'kas harapan menghitung tunai, refund tunai, kas masuk, dan kas keluar',
    () async {
      final expected = await datasource.calculateExpectedCash('shift-1', 50000);

      // 50.000 modal + 100.000 penjualan tunai - 10.000 refund tunai
      // + 10.000 kas masuk - 2.000 kas keluar.
      expect(expected, 148000);
      expect(
        api.requests
            .firstWhere((request) => request.path == '/rest/v1/payments')
            .uri
            .queryParameters['method'],
        'eq.cash',
      );
      expect(
        api.requests
            .firstWhere((request) => request.path == '/rest/v1/refunds')
            .uri
            .queryParameters['method'],
        'eq.cash',
      );
    },
  );

  test('buka baru memakai UUID perangkat dan RPC idempoten', () async {
    final shift = await datasource.openShift('outlet-1', 'kasir-1', 125000);
    expect(shift.id, 'new-shift');
    expect(shift.startTime, DateTime.parse('2026-09-04T06:46:02Z'));
    expect(shift.openingCash, 125000);
    final body = api.rpcBody('open_shift_idempotent');
    expect(
      body['p_shift_id'],
      isA<String>().having((v) => v.length, 'length', 36),
    );
    expect(body['p_outlet_id'], 'outlet-1');
    expect(body['p_kasir_id'], 'kasir-1');
    expect(body['p_opening_cash'], 125000.0);
    expect(DateTime.tryParse(body['p_started_at'] as String), isNotNull);
  });

  test('gagal memuat riwayat tidak memblokir shift aktif', () async {
    api.failRecentShifts = true;

    final results = await Future.wait([
      datasource.fetchActiveShift('outlet-1', 'kasir-1'),
      datasource.fetchRecentShifts('outlet-1', 'kasir-1'),
    ]);

    expect((results[0] as dynamic).id, 'shift-active');
    expect(results[1], isEmpty);
  });

  test('bentrok sesi lama tidak dilaporkan sebagai buka baru sukses', () async {
    api.insertErrorCode = '23505';
    await expectLater(
      datasource.openShift('outlet-1', 'kasir-1', 125000),
      throwsA(
        isA<ActiveShiftExistsException>()
            .having((e) => e.shift.id, 'existing shift', 'shift-active')
            .having((e) => e.shift.openingCash, 'original cash', 50000)
            .having(
              (e) => e.message,
              'message',
              contains('modal baru belum disimpan'),
            ),
      ),
    );
    expect(api.requests.map((r) => r.method), ['POST', 'GET']);
  });

  test('bentrok tanpa sesi aktif tetap gagal, tidak mengarang sesi', () async {
    api.insertErrorCode = '23505';
    api.activeShiftAvailable = false;
    await expectLater(
      datasource.openShift('outlet-1', 'kasir-1', 0),
      throwsA(isA<PostgrestException>()),
    );
  });

  test('error insert lain tidak dipulihkan sebagai sesi aktif', () async {
    api.insertErrorCode = '42501';
    await expectLater(
      datasource.openShift('outlet-1', 'kasir-1', 0),
      throwsA(isA<PostgrestException>()),
    );
    expect(api.requests, hasLength(1));
  });

  test('kas keluar mengirim kategori pengeluaran ke RPC atomik', () async {
    final movement = await datasource.addCashMovement(
      shiftId: 'shift-1',
      outletId: 'outlet-1',
      type: 'out',
      amount: 15000,
      note: 'Belanja bahan',
      expenseCategory: 'bahan_baku',
    );

    expect(movement.type, 'out');
    expect(movement.amount, 15000);
    final body = api.rpcBody('record_cash_movement_idempotent');
    expect(body['p_request_id'], isA<String>());
    expect(body['p_shift_id'], 'shift-1');
    expect(body['p_outlet_id'], 'outlet-1');
    expect(body['p_type'], 'out');
    expect(body['p_amount'], 15000.0);
    expect(body['p_note'], 'Belanja bahan');
    expect(body['p_expense_category'], 'bahan_baku');
    expect(DateTime.tryParse(body['p_created_at'] as String), isNotNull);
  });

  test('role manajemen dapat memuat daftar shift kasir aktif', () async {
    final shifts = await datasource.fetchActiveShiftsForManagement('outlet-1');

    expect(shifts, hasLength(1));
    expect(shifts.single.id, 'shift-active');
    expect(shifts.single.cashierName, 'Siti Kasir');
    final request = api.requests.firstWhere(
      (entry) => entry.path == '/rest/v1/shifts',
    );
    expect(request.uri.queryParameters['outlet_id'], 'eq.outlet-1');
    expect(request.uri.queryParameters['end_time'], 'is.null');
  });

  test('tutup shift mengembalikan laporan server', () async {
    final report = await datasource.closeShift(
      shiftId: 'shift-1',
      closingCash: 147500,
      notes: 'Selisih lima ratus',
    );

    expect(report.cashierName, 'Kasir');
    expect(report.cashDifference, -500);
    expect(report.products.single.quantity, 2);
    expect(report.cashOut, 2000);
    expect(report.expenses.single.description, 'Belanja es');
    final body = api.rpcBody('close_shift_idempotent_with_report');
    expect(body['p_shift_id'], 'shift-1');
    expect(body['p_closing_cash'], 147500.0);
    expect(body['p_notes'], 'Selisih lima ratus');
    expect(DateTime.tryParse(body['p_closed_at'] as String), isNotNull);
  });
}

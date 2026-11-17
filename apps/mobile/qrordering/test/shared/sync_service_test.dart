import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/shared/services/offline_queue_service.dart';
import 'package:qrordering/shared/services/sync_service.dart';
import 'package:qrordering/shared/services/transaction_journal_service.dart';

String _sessionJson(String userId) {
  final expiresAt = DateTime.now().add(const Duration(hours: 1));
  final encodedClaims = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': userId,
            'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
            'role': 'authenticated',
          }),
        ),
      )
      .replaceAll('=', '');
  return jsonEncode({
    'access_token': 'header.$encodedClaims.signature',
    'refresh_token': 'test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'user': {
      'id': userId,
      'aud': 'authenticated',
      'role': 'authenticated',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'created_at': '2026-01-01T00:00:00Z',
    },
  });
}

/// Regression: mesin "sinkron belakangan".
///
/// Sejak semua transaksi lewat antrean, SyncService-lah satu-satunya jalan uang
/// sampai ke server. Dua perilaku yang wajib dijaga:
/// - order yang DITOLAK server tidak boleh memblok order valid di belakangnya
///   (head-of-line blocking) — kalau memblok, satu order rusak membekukan
///   seluruh pemasukan hari itu;
/// - kegagalan JARINGAN tidak boleh dianggap penolakan — kalau salah klasifikasi,
///   transaksi sah dibuang ke dead-letter hanya karena internet putus sesaat.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HttpServer server;
  late List<String> postedOrderIds;
  late List<String> postedShiftIds;
  late List<String> mutationOrder;
  late Set<String> rejectIds;
  late Set<String> authRejectIds;
  late Set<String> transientOrderIds;
  late Set<String> rejectPaymentKeys;
  late Set<String> transientPaymentKeys;
  late List<String> postedPaymentKeys;
  late List<String?> postedPaymentPaidAts;
  late List<String> finalizedSplitOrders;
  late List<String> postedAppendRequestIds;
  late List<String> postedClosedShiftIds;
  late List<String> postedCashMovementIds;
  late Completer<void> slowOrderStarted;
  late Completer<void> releaseSlowOrder;

  Map<String, dynamic> payload(String id) => {
    'kind': 'paid',
    'clientOrderId': id,
    'localReceiptNo': 'A7-001',
    'outletId': 'outlet-1',
    'createdBy': 'kasir-1',
    'orderType': 'dine_in',
    'subtotal': 10000,
    'total': 10000,
    'paymentMethod': 'cash',
    'amount': 10000,
    'idempotencyKey': 'idem-$id',
    'shiftId': 'shift-1',
    'createdAt': '2026-07-16T03:04:05.000Z',
    'items': [
      {
        'menuItemId': 'menu-1',
        'name': 'Menu test',
        'quantity': 1,
        'unitPrice': 10000,
        'subtotal': 10000,
        'extras': <Map<String, dynamic>>[],
      },
    ],
  };

  /// Menulis langsung untuk mensimulasikan antrean dari versi lama atau data
  /// Hive yang berubah setelah disimpan. Enqueue produksi sekarang menolak
  /// payload ini sebelum commit, sedangkan SyncService tetap wajib mampu
  /// mengisolasi record lama tanpa memblok transaksi berikutnya.
  Future<void> enqueueRaw(Map<String, dynamic> value) async {
    await Hive.box(OfflineQueueService.boxName).add(jsonEncode(value));
    OfflineQueueService.instance.init();
  }

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});

    tmp = await Directory.systemTemp.createTemp('sync_service_test');
    Hive.init(tmp.path);
    await Hive.openBox(OfflineQueueService.boxName);
    await Hive.openBox(OfflineQueueService.deadBoxName);
    await Hive.openBox(TransactionJournalService.boxName);
    await Hive.box(OfflineQueueService.boxName).clear();
    await Hive.box(OfflineQueueService.deadBoxName).clear();
    await Hive.box(TransactionJournalService.boxName).clear();
    OfflineQueueService.instance.init();
    TransactionJournalService.instance.init();
    SyncService.instance.lastPaidOrderSynced.value = null;

    postedOrderIds = [];
    postedShiftIds = [];
    mutationOrder = [];
    rejectIds = {};
    authRejectIds = {};
    transientOrderIds = {};
    rejectPaymentKeys = {};
    transientPaymentKeys = {};
    postedPaymentKeys = [];
    postedPaymentPaidAts = [];
    finalizedSplitOrders = [];
    postedAppendRequestIds = [];
    postedClosedShiftIds = [];
    postedCashMovementIds = [];
    slowOrderStarted = Completer<void>();
    releaseSlowOrder = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final res = req.response..headers.contentType = ContentType.json;

      if (req.uri.path == '/rest/v1/rpc/get_next_pos_order_number') {
        res.write(jsonEncode('001'));
        await res.close();
        return;
      }

      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/open_shift_idempotent') {
        final body = jsonDecode(raw) as Map;
        final id = body['p_shift_id'] as String;
        postedShiftIds.add(id);
        mutationOrder.add('shift:$id');
        res.write(
          jsonEncode({
            'id': id,
            'outlet_id': body['p_outlet_id'],
            'kasir_id': body['p_kasir_id'],
            'start_time': body['p_started_at'],
            'opening_cash': body['p_opening_cash'],
          }),
        );
        await res.close();
        return;
      }

      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/close_shift_idempotent_with_report') {
        final body = jsonDecode(raw) as Map;
        final id = body['p_shift_id'] as String;
        postedClosedShiftIds.add(id);
        mutationOrder.add('close:$id');
        res.write(jsonEncode(<String, dynamic>{'shift_id': id}));
        await res.close();
        return;
      }

      if (req.method == 'POST' &&
          req.uri.path ==
              '/rest/v1/rpc/record_cash_movement_idempotent') {
        final body = jsonDecode(raw) as Map;
        final id = body['p_request_id'] as String;
        postedCashMovementIds.add(id);
        mutationOrder.add('cash:$id');
        res.write(
          jsonEncode({
            'id': id,
            'shift_id': body['p_shift_id'],
            'outlet_id': body['p_outlet_id'],
            'type': body['p_type'],
            'amount': body['p_amount'],
            'note': body['p_note'],
            'created_by': 'kasir-1',
            'created_at': body['p_created_at'],
          }),
        );
        await res.close();
        return;
      }

      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/create_pos_order') {
        final body = jsonDecode(raw) as Map;
        final id = body['p_order_id'] as String? ?? 'generated-order';
        if (id == 'order-lambat') {
          if (!slowOrderStarted.isCompleted) slowOrderStarted.complete();
          await releaseSlowOrder.future;
        }
        if (authRejectIds.contains(id)) {
          res.statusCode = 401;
          res.write(
            jsonEncode({
              'message': 'JWT expired',
              'code': 'PGRST301',
              'details': '',
            }),
          );
          await res.close();
          return;
        }
        if (transientOrderIds.contains(id)) {
          res.statusCode = 503;
          res.write(
            jsonEncode({
              'message': 'PostgREST temporarily unavailable',
              'code': 'PGRST002',
              'details': '',
            }),
          );
          await res.close();
          return;
        }
        // Server MENOLAK order tertentu (mis. langgar constraint/RLS).
        if (rejectIds.contains(id)) {
          res.statusCode = 400;
          res.write(
            jsonEncode({
              'message': 'melanggar constraint',
              'code': '23514',
              'details': '',
            }),
          );
          await res.close();
          return;
        }
        postedOrderIds.add(id);
        mutationOrder.add('order:$id');
        res.write(
          jsonEncode({
            'order_id': id,
            'order_number': '001',
            'total_amount':
                body['p_total_amount'] ?? body['p_subtotal'] ?? 10000,
          }),
        );
        await res.close();
        return;
      }
      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/record_pos_payment_with_context') {
        final body = jsonDecode(raw) as Map;
        final key = body['p_idempotency_key'] as String? ?? '';
        if (transientPaymentKeys.contains(key)) {
          res.statusCode = 503;
          res.write(
            jsonEncode({
              'message': 'PostgREST temporarily unavailable',
              'code': 'PGRST002',
              'details': '',
            }),
          );
          await res.close();
          return;
        }
        if (rejectPaymentKeys.contains(key)) {
          res.statusCode = 400;
          res.write(
            jsonEncode({
              'message': 'Shift pembayaran sudah ditutup',
              'code': '22023',
              'details': '',
            }),
          );
          await res.close();
          return;
        }
        postedPaymentKeys.add(key);
        mutationOrder.add('payment:$key');
        postedPaymentPaidAts.add(body['p_paid_at'] as String?);
        res.write(
          jsonEncode({
            'payment_id': 'payment-${postedOrderIds.length}',
            'paid_total': 10000,
            'order_total': 10000,
            'status': 'paid',
          }),
        );
        await res.close();
        return;
      }
      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/finalize_split_payment') {
        final body = jsonDecode(raw) as Map;
        finalizedSplitOrders.add(body['p_order_id'] as String);
        res.write(jsonEncode({'status': 'paid'}));
        await res.close();
        return;
      }
      if (req.method == 'POST' &&
          req.uri.path == '/rest/v1/rpc/append_order_items') {
        final body = jsonDecode(raw) as Map;
        postedAppendRequestIds.add(body['p_request_id'] as String);
        res.write(jsonEncode(const []));
        await res.close();
        return;
      }
      res.write(jsonEncode(req.method == 'GET' ? [] : []));
      await res.close();
    });

    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
    await Supabase.instance.client.auth.recoverSession(_sessionJson('kasir-1'));
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await server.close(force: true);
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('antrean terkuras & entri dihapus setelah sukses', () async {
    await OfflineQueueService.instance.enqueue(payload('order-a'));
    await OfflineQueueService.instance.enqueue(payload('order-b'));

    await SyncService.instance.sync();

    expect(postedOrderIds, ['order-a', 'order-b']);
    expect(OfflineQueueService.instance.pendingCount.value, 0);
    expect(OfflineQueueService.instance.deadCount.value, 0);
  });

  test('shift lokal dibuat sebelum order dependennya dikirim', () async {
    await TransactionJournalService.instance.enqueue(
      id: 'shift-open-shift-offline-1',
      type: 'shift_open',
      payload: const {
        'shiftId': 'shift-offline-1',
        'outletId': 'outlet-1',
        'kasirId': 'kasir-1',
        'expectedUserId': 'kasir-1',
        'openingCash': 50000,
        'startedAt': '2026-07-16T02:00:00.000Z',
        'clockSource': 'server_offset',
      },
    );
    final order = payload('order-offline-shift')
      ..['shiftId'] = 'shift-offline-1';
    await OfflineQueueService.instance.enqueue(order);

    await SyncService.instance.sync();

    expect(postedShiftIds, ['shift-offline-1']);
    expect(postedOrderIds, ['order-offline-shift']);
    expect(mutationOrder, [
      'shift:shift-offline-1',
      'order:order-offline-shift',
      'payment:idem-order-offline-shift',
    ]);
    expect(TransactionJournalService.instance.pendingCount.value, 0);
    expect(OfflineQueueService.instance.pendingCount.value, 0);
  });

  test(
    'pemicu sync saat drain berjalan menguras transaksi yang baru masuk',
    () async {
      await OfflineQueueService.instance.enqueue(payload('order-lambat'));

      final firstSync = SyncService.instance.sync();
      await slowOrderStarted.future;
      await OfflineQueueService.instance.enqueue(payload('order-baru'));

      // Panggilan ini terjadi ketika snapshot pass pertama sudah terbentuk.
      // Implementasi lama mengabaikannya sehingga order-baru tertinggal.
      final overlappingSync = SyncService.instance.sync();
      releaseSlowOrder.complete();
      await Future.wait([firstSync, overlappingSync]);

      expect(postedOrderIds, ['order-lambat', 'order-baru']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
    },
  );

  test('tanpa user aktif transaksi pembuat tetap menunggu login', () async {
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    await OfflineQueueService.instance.enqueue(payload('order-menunggu'));

    await SyncService.instance.sync();

    expect(postedOrderIds, isEmpty);
    expect(OfflineQueueService.instance.pendingCount.value, 1);
    expect(OfflineQueueService.instance.deadCount.value, 0);
  });

  test(
    'order ditolak server → dead-letter, TIDAK memblok order di belakangnya',
    () async {
      rejectIds = {'order-rusak'};
      await OfflineQueueService.instance.enqueue(payload('order-rusak'));
      await OfflineQueueService.instance.enqueue(payload('order-valid'));

      await SyncService.instance.sync();

      expect(postedOrderIds, [
        'order-valid',
      ], reason: 'order valid di belakang wajib tetap terkirim');
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 1);

      final dead = OfflineQueueService.instance.deadLetters().first;
      expect(dead.payload['clientOrderId'], 'order-rusak');
      expect(
        dead.error,
        contains('23514'),
        reason: 'alasan penolakan disimpan agar bisa ditelusuri kasir',
      );
    },
  );

  test(
    'metadata antrean rusak masuk dead-letter dan tidak memblok order valid',
    () async {
      final corrupt = payload('order-metadata-rusak')..['createdBy'] = 123;
      await enqueueRaw(corrupt);
      await OfflineQueueService.instance.enqueue(
        payload('order-sesudah-rusak'),
      );

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-sesudah-rusak']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 1);
      final dead = OfflineQueueService.instance.deadLetters().single;
      expect(dead.payload['clientOrderId'], 'order-metadata-rusak');
      expect(dead.error, contains('createdBy'));
    },
  );

  test(
    'item kosong atau kuantitas invalid diisolasi sebelum mencapai server',
    () async {
      final emptyItems = payload('order-item-kosong')..['items'] = const [];
      final invalidQuantity = payload('order-qty-invalid');
      (invalidQuantity['items'] as List).first['quantity'] = 0;
      await enqueueRaw(emptyItems);
      await enqueueRaw(invalidQuantity);
      await OfflineQueueService.instance.enqueue(payload('order-item-valid'));

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-item-valid']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 2);
      expect(
        OfflineQueueService.instance.deadLetters().map((entry) => entry.error),
        containsAll([contains('items'), contains('Kuantitas')]),
      );
    },
  );

  test(
    'nominal dan metode pembayaran invalid tidak dikirim ke server',
    () async {
      final invalidAmount = payload('order-amount-invalid')..['amount'] = 0;
      final invalidMethod = payload('order-method-invalid')
        ..['paymentMethod'] = 'crypto';
      await enqueueRaw(invalidAmount);
      await enqueueRaw(invalidMethod);
      await OfflineQueueService.instance.enqueue(payload('order-bayar-valid'));

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-bayar-valid']);
      expect(postedPaymentKeys, ['idem-order-bayar-valid']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 2);
    },
  );

  test(
    'transaksi tanpa identitas pembuat diisolasi dan tidak dikirim dengan akun lain',
    () async {
      final legacy = payload('order-tanpa-pembuat')..remove('createdBy');
      await enqueueRaw(legacy);
      await OfflineQueueService.instance.enqueue(payload('order-beridentitas'));

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-beridentitas']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 1);
      expect(
        OfflineQueueService.instance.deadLetters().single.error,
        contains('createdBy wajib diisi'),
      );
    },
  );

  test(
    'record Hive korup diisolasi dan tidak memblok order valid berikutnya',
    () async {
      await Hive.box(
        OfflineQueueService.boxName,
      ).add('{json transaksi terpotong');
      await OfflineQueueService.instance.enqueue(payload('order-setelah-json'));
      OfflineQueueService.instance.init();

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-setelah-json']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 1);
      final dead = OfflineQueueService.instance.deadLetters().single;
      expect(dead.payload['_offlineQueueCorrupt'], isTrue);
      expect(dead.payload['_offlineQueueRaw'], contains('terpotong'));
    },
  );

  test('gagal jaringan → tetap di antrean, BUKAN dead-letter', () async {
    await OfflineQueueService.instance.enqueue(payload('order-a'));
    // Server mati total → error jaringan, bukan penolakan server.
    await server.close(force: true);

    await SyncService.instance.sync();

    expect(
      OfflineQueueService.instance.pendingCount.value,
      1,
      reason: 'transaksi sah harus menunggu koneksi, bukan dibuang',
    );
    expect(OfflineQueueService.instance.deadCount.value, 0);
  });

  test('JWT kedaluwarsa → tetap antre dan sukses setelah sesi pulih', () async {
    authRejectIds = {'order-auth'};
    await OfflineQueueService.instance.enqueue(payload('order-auth'));

    await SyncService.instance.sync();

    expect(OfflineQueueService.instance.pendingCount.value, 1);
    expect(OfflineQueueService.instance.deadCount.value, 0);

    authRejectIds = {};
    await SyncService.instance.sync();

    expect(postedOrderIds, ['order-auth']);
    expect(OfflineQueueService.instance.pendingCount.value, 0);
    expect(OfflineQueueService.instance.deadCount.value, 0);
  });

  test('penolakan created_by bersifat dapat dipulihkan', () {
    const error = PostgrestException(
      message: 'created_by harus merupakan pengguna yang sedang login',
      code: '42501',
    );
    expect(isRetryableSyncFailure(error), isTrue);
  });

  test('constraint bisnis tetap dianggap penolakan permanen', () {
    const error = PostgrestException(
      message: 'melanggar constraint',
      code: '23514',
    );
    expect(isRetryableSyncFailure(error), isFalse);
  });

  test(
    'sinyal order tersinkron dipancarkan (untuk alert stok menipis)',
    () async {
      await OfflineQueueService.instance.enqueue(payload('order-a'));

      await SyncService.instance.sync();

      expect(SyncService.instance.lastPaidOrderSynced.value, 'order-a');
    },
  );

  test('draft tidak memancarkan sinyal order terbayar', () async {
    final p = payload('draft-a')..['kind'] = 'draft';
    await OfflineQueueService.instance.enqueue(p);

    await SyncService.instance.sync();

    expect(OfflineQueueService.instance.pendingCount.value, 0);
    expect(
      SyncService.instance.lastPaidOrderSynced.value,
      isNull,
      reason: 'draf belum dibayar → jangan picu pemeriksaan stok',
    );
  });

  test('confirmed tidak memancarkan sinyal order terbayar', () async {
    final p = payload('confirmed-a')..['kind'] = 'confirmed';
    await OfflineQueueService.instance.enqueue(p);

    await SyncService.instance.sync();

    expect(OfflineQueueService.instance.pendingCount.value, 0);
    expect(
      SyncService.instance.lastPaidOrderSynced.value,
      isNull,
      reason: 'order ke dapur belum dibayar → jangan picu sinyal pembayaran',
    );
  });

  test(
    'retry dead-letter mengembalikan ke antrean & bisa lolos setelah diperbaiki',
    () async {
      rejectIds = {'order-x'};
      await OfflineQueueService.instance.enqueue(payload('order-x'));
      await SyncService.instance.sync();
      expect(OfflineQueueService.instance.deadCount.value, 1);

      // Sisi server sudah dibereskan (mis. stok/constraint diperbaiki owner).
      rejectIds = {};
      await OfflineQueueService.instance.retryAllDeadLetters();
      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-x']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(OfflineQueueService.instance.deadCount.value, 0);
    },
  );

  test(
    'jurnal pembayaran order terkirim lalu dihapus setelah konfirmasi',
    () async {
      await TransactionJournalService.instance.enqueue(
        id: 'journal-existing-1',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-existing-1',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-existing-1',
          'paidAt': '2026-07-30T04:05:06.000Z',
        },
      );

      await SyncService.instance.sync();

      expect(postedPaymentKeys, ['payment-existing-1']);
      expect(postedPaymentPaidAts, ['2026-07-30T04:05:06.000Z']);
      expect(TransactionJournalService.instance.pendingCount.value, 0);
      expect(TransactionJournalService.instance.attentionCount.value, 0);
    },
  );

  test(
    'mutasi anak menunggu sampai order lokal berhasil dibuat di server',
    () async {
      final parent = payload('order-parent')..['kind'] = 'confirmed';
      transientOrderIds = {'order-parent'};
      await OfflineQueueService.instance.enqueue(parent);
      await TransactionJournalService.instance.enqueue(
        id: 'journal-child',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-parent',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-child',
          'paidAt': '2026-07-30T04:05:06.000Z',
        },
      );

      await SyncService.instance.sync();

      expect(OfflineQueueService.instance.pendingCount.value, 1);
      expect(TransactionJournalService.instance.pendingCount.value, 1);
      expect(postedPaymentKeys, isEmpty);
      expect(TransactionJournalService.instance.attentionCount.value, 0);

      transientOrderIds.clear();
      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-parent']);
      expect(postedPaymentKeys, ['payment-child']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
      expect(TransactionJournalService.instance.pendingCount.value, 0);
    },
  );

  test('split payment dan finalisasi diputar ulang sesuai urutan', () async {
    await TransactionJournalService.instance.enqueue(
      id: 'journal-split-1',
      type: 'split_payment',
      payload: const {
        'orderId': 'order-split-1',
        'outletId': 'outlet-1',
        'shiftId': 'shift-1',
        'expectedUserId': 'kasir-1',
        'method': 'qris',
        'amount': 6000,
        'idempotencyKey': 'payment-split-1',
        'paidAt': '2026-07-30T05:06:07.000Z',
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await TransactionJournalService.instance.enqueue(
      id: 'journal-finalize-1',
      type: 'split_finalize',
      payload: const {'orderId': 'order-split-1', 'expectedUserId': 'kasir-1'},
    );

    await SyncService.instance.sync();

    expect(postedPaymentKeys, ['payment-split-1']);
    expect(postedPaymentPaidAts, ['2026-07-30T05:06:07.000Z']);
    expect(finalizedSplitOrders, ['order-split-1']);
    expect(TransactionJournalService.instance.pendingCount.value, 0);
  });

  test(
    'split payment di outbox memakai waktu tiap pembayaran dan finalisasi',
    () async {
      final order = payload('order-split-outbox')
        ..remove('paymentMethod')
        ..remove('amount')
        ..remove('idempotencyKey')
        ..['payments'] = const [
          {
            'method': 'cash',
            'amount': 4000,
            'idempotencyKey': 'outbox-split-cash',
            'paidAt': '2026-07-30T05:00:00.000Z',
            'paidAtClockSource': 'server_offset',
          },
          {
            'method': 'qris',
            'amount': 6000,
            'idempotencyKey': 'outbox-split-qris',
            'paidAt': '2026-07-30T05:05:00.000Z',
            'paidAtClockSource': 'server_offset',
          },
        ];
      await OfflineQueueService.instance.enqueue(order);

      await SyncService.instance.sync();

      expect(postedOrderIds, ['order-split-outbox']);
      expect(postedPaymentKeys, ['outbox-split-cash', 'outbox-split-qris']);
      expect(postedPaymentPaidAts, [
        '2026-07-30T05:00:00.000Z',
        '2026-07-30T05:05:00.000Z',
      ]);
      expect(finalizedSplitOrders, ['order-split-outbox']);
      expect(OfflineQueueService.instance.pendingCount.value, 0);
    },
  );

  test(
    'append item offline diputar ulang dengan request id yang sama',
    () async {
      await TransactionJournalService.instance.enqueue(
        id: 'append-request-1',
        type: 'append_order_items',
        payload: const {
          'orderId': 'order-append-1',
          'outletId': 'outlet-1',
          'expectedUserId': 'kasir-1',
          'requestId': 'append-request-1',
          'taxPercent': 10,
          'taxActive': true,
          'serviceChargePercent': 5,
          'items': [
            {
              'menu_item_id': 'menu-1',
              'quantity': 1,
              'unit_price': 10000,
              'extras': [],
            },
          ],
        },
      );

      await SyncService.instance.sync();

      expect(postedAppendRequestIds, ['append-request-1']);
      expect(
        TransactionJournalService.instance.get('append-request-1'),
        isNull,
      );
    },
  );

  test(
    'jurnal nominal invalid ditandai perlu ditinjau tanpa request server',
    () async {
      await TransactionJournalService.instance.enqueue(
        id: 'journal-invalid-amount',
        type: 'split_payment',
        payload: const {
          'orderId': 'order-invalid-amount',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 0,
          'idempotencyKey': 'payment-invalid-amount',
        },
      );

      await SyncService.instance.sync();

      expect(postedPaymentKeys, isEmpty);
      expect(TransactionJournalService.instance.pendingCount.value, 0);
      expect(TransactionJournalService.instance.attentionCount.value, 1);
    },
  );

  test('jurnal lama memakai waktu enqueue sebagai waktu bayar', () async {
    await TransactionJournalService.instance.enqueue(
      id: 'journal-legacy-time',
      type: 'existing_payment',
      payload: const {
        'orderId': 'order-legacy-time',
        'outletId': 'outlet-1',
        'shiftId': 'shift-1',
        'expectedUserId': 'kasir-1',
        'method': 'cash',
        'amount': 10000,
        'idempotencyKey': 'payment-legacy-time',
      },
    );
    final createdAt =
        TransactionJournalService.instance.get(
              'journal-legacy-time',
            )!['createdAt']
            as String;

    await SyncService.instance.sync();

    expect(postedPaymentKeys, ['payment-legacy-time']);
    expect(postedPaymentPaidAts, [createdAt]);
    expect(TransactionJournalService.instance.pendingCount.value, 0);
  });

  test('jurnal kasir lain ditahan sampai akun pembuat masuk', () async {
    await TransactionJournalService.instance.enqueue(
      id: 'journal-other-user',
      type: 'existing_payment',
      payload: const {
        'orderId': 'order-other-user',
        'outletId': 'outlet-1',
        'shiftId': 'shift-1',
        'expectedUserId': 'kasir-lain',
        'method': 'cash',
        'amount': 10000,
        'idempotencyKey': 'payment-other-user',
      },
    );

    await SyncService.instance.sync();

    expect(postedPaymentKeys, isEmpty);
    expect(TransactionJournalService.instance.pendingCount.value, 1);
    expect(TransactionJournalService.instance.attentionCount.value, 0);
  });

  test(
    'penolakan permanen satu pembayaran tidak memblok pembayaran berikutnya',
    () async {
      rejectPaymentKeys = {'payment-rejected'};
      await TransactionJournalService.instance.enqueue(
        id: 'journal-rejected',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-rejected',
          'outletId': 'outlet-1',
          'shiftId': 'shift-old',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-rejected',
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await TransactionJournalService.instance.enqueue(
        id: 'journal-valid',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-valid-payment',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-valid',
        },
      );

      await SyncService.instance.sync();

      expect(postedPaymentKeys, ['payment-valid']);
      expect(TransactionJournalService.instance.pendingCount.value, 0);
      expect(TransactionJournalService.instance.attentionCount.value, 1);
      expect(
        TransactionJournalService.instance
            .diagnostics(attentionOnly: true)
            .single
            .readableReason,
        contains('Till pada payload sudah ditutup'),
      );
    },
  );

  test(
    'metadata jurnal rusak tidak memblok pembayaran valid berikutnya',
    () async {
      await TransactionJournalService.instance.enqueue(
        id: 'journal-corrupt-metadata',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-corrupt-metadata',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 123,
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-corrupt-metadata',
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await TransactionJournalService.instance.enqueue(
        id: 'journal-after-corrupt',
        type: 'existing_payment',
        payload: const {
          'orderId': 'order-after-corrupt',
          'outletId': 'outlet-1',
          'shiftId': 'shift-1',
          'expectedUserId': 'kasir-1',
          'method': 'cash',
          'amount': 10000,
          'idempotencyKey': 'payment-after-corrupt',
        },
      );

      await SyncService.instance.sync();

      expect(postedPaymentKeys, ['payment-after-corrupt']);
      expect(TransactionJournalService.instance.pendingCount.value, 0);
      expect(TransactionJournalService.instance.attentionCount.value, 1);
      expect(
        TransactionJournalService.instance
            .diagnostics(attentionOnly: true)
            .single
            .lastError,
        contains('expectedUserId'),
      );
    },
  );

  test('gangguan server sementara mempertahankan jurnal untuk retry', () async {
    transientPaymentKeys = {'payment-transient'};
    await TransactionJournalService.instance.enqueue(
      id: 'journal-transient',
      type: 'existing_payment',
      payload: const {
        'orderId': 'order-transient',
        'outletId': 'outlet-1',
        'shiftId': 'shift-1',
        'expectedUserId': 'kasir-1',
        'method': 'cash',
        'amount': 10000,
        'idempotencyKey': 'payment-transient',
      },
    );

    await SyncService.instance.sync();

    expect(postedPaymentKeys, isEmpty);
    expect(TransactionJournalService.instance.pendingCount.value, 1);
    expect(TransactionJournalService.instance.attentionCount.value, 0);

    transientPaymentKeys = {};
    await SyncService.instance.sync();
    expect(postedPaymentKeys, ['payment-transient']);
    expect(TransactionJournalService.instance.pendingCount.value, 0);
  });

  test('penutupan shift selalu dikirim setelah pembayaran shift', () async {
    // Sengaja enqueue penutupan lebih dahulu untuk membuktikan urutan tidak
    // bergantung pada jam perangkat atau urutan tulis lokal.
    await TransactionJournalService.instance.enqueue(
      id: 'shift-close-shift-1',
      type: 'shift_close',
      payload: const {
        'shiftId': 'shift-1',
        'outletId': 'outlet-1',
        'expectedUserId': 'kasir-1',
        'closingCash': 110000,
        'closedAt': '2026-07-16T04:00:00.000Z',
        'clockSource': 'server_offset',
      },
    );
    await TransactionJournalService.instance.enqueue(
      id: 'payment-before-close',
      type: 'existing_payment',
      payload: const {
        'orderId': 'order-before-close',
        'outletId': 'outlet-1',
        'shiftId': 'shift-1',
        'expectedUserId': 'kasir-1',
        'method': 'cash',
        'amount': 10000,
        'idempotencyKey': 'payment-before-close',
      },
    );
    await TransactionJournalService.instance.enqueue(
      id: 'cash-movement-before-close',
      type: 'cash_movement',
      payload: const {
        'requestId': 'cash-request-1',
        'shiftId': 'shift-1',
        'outletId': 'outlet-1',
        'expectedUserId': 'kasir-1',
        'type': 'out',
        'amount': 5000,
        'note': 'Belanja es',
        'expenseCategory': 'operasional',
        'createdAt': '2026-07-16T03:30:00.000Z',
        'clockSource': 'server_offset',
      },
    );

    await SyncService.instance.sync();

    expect(postedPaymentKeys, ['payment-before-close']);
    expect(postedCashMovementIds, ['cash-request-1']);
    expect(postedClosedShiftIds, ['shift-1']);
    expect(
      mutationOrder.indexOf('payment:payment-before-close'),
      lessThan(mutationOrder.indexOf('close:shift-1')),
    );
    expect(
      mutationOrder.indexOf('cash:cash-request-1'),
      lessThan(mutationOrder.indexOf('close:shift-1')),
    );
    expect(TransactionJournalService.instance.pendingCount.value, 0);
  });
}

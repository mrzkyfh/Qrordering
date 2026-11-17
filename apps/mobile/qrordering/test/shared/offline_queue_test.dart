import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrordering/shared/services/offline_queue_service.dart';

Map<String, dynamic> _payload(
  String id, {
  String kind = 'paid',
  num total = 10000,
  String? localReceiptNo,
}) {
  return <String, dynamic>{
    'kind': kind,
    'clientOrderId': id,
    'localReceiptNo': ?localReceiptNo,
    'outletId': 'outlet-1',
    'createdBy': 'kasir-1',
    'orderType': 'dine_in',
    'subtotal': total,
    'total': total,
    'createdAt': '2026-08-01T00:00:00.000Z',
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'menuItemId': 'menu-1',
        'quantity': 1,
        'unitPrice': total,
        'subtotal': total,
        'extras': <Map<String, dynamic>>[],
      },
    ],
    if (kind == 'paid') ...<String, dynamic>{
      'shiftId': 'shift-1',
      'paymentMethod': 'cash',
      'amount': total > 0 ? total : 1,
      'idempotencyKey': 'idem-$id',
    },
  };
}

/// Menguji ketahanan antrean offline: dead-letter mencegah head-of-line
/// blocking, payload tidak hilang, dan retry mengembalikan ke antrean aktif.
void main() {
  late Directory tmp;
  final q = OfflineQueueService.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('offline_queue_test');
    Hive.init(tmp.path);
    await Hive.openBox(OfflineQueueService.boxName);
    await Hive.openBox(OfflineQueueService.deadBoxName);
    await Hive.box(OfflineQueueService.boxName).clear();
    await Hive.box(OfflineQueueService.deadBoxName).clear();
    q.init();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('enqueue menambah pending count', () async {
    await q.enqueue(_payload('a', kind: 'draft'));
    expect(q.pendingCount.value, 1);
    expect(q.deadCount.value, 0);
  });

  test(
    'restart aplikasi tidak menghilangkan pending dan dead-letter',
    () async {
      await q.enqueue(_payload('persist-pending', localReceiptNo: 'P-001'));
      await q.enqueue(_payload('persist-dead', localReceiptNo: 'D-001'));
      final deadKey = q
          .all()
          .firstWhere((entry) => entry.value['clientOrderId'] == 'persist-dead')
          .key;
      await q.moveToDeadLetter(deadKey, 'server menolak');

      await Hive.box(OfflineQueueService.boxName).close();
      await Hive.box(OfflineQueueService.deadBoxName).close();
      await Hive.openBox(OfflineQueueService.boxName);
      await Hive.openBox(OfflineQueueService.deadBoxName);
      q.init();

      expect(q.pendingCount.value, 1);
      expect(q.deadCount.value, 1);
      expect(q.all().single.value['localReceiptNo'], 'P-001');
      expect(q.deadLetters().single.localReference, 'D-001');
    },
  );

  test(
    'moveToDeadLetter: keluar dari antrean aktif, masuk dead-letter, payload utuh',
    () async {
      await q.enqueue(_payload('x', total: 42));
      final key = q.all().first.key;

      await q.moveToDeadLetter(key, 'PostgrestException 23514: cek gagal');

      expect(
        q.pendingCount.value,
        0,
        reason: 'tidak lagi memblok antrean aktif',
      );
      expect(q.deadCount.value, 1);
      final dl = q.deadLetters();
      expect(dl.length, 1);
      expect(dl.first.error, contains('23514'));
      expect(dl.first.payload['clientOrderId'], 'x');
      expect(dl.first.payload['total'], 42);
    },
  );

  test('diagnostik menyertakan item dan pilihan untuk pemulihan', () async {
    final payload = _payload('diagnostic', localReceiptNo: 'RD-005');
    final item = (payload['items'] as List).single as Map<String, dynamic>;
    item['name'] = 'Vanilla Latte';
    item['extras'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'menuExtraOptionId': 'option-hot',
        'optionName': 'HOT',
        'price': 0,
      },
    ];
    await q.enqueue(payload);
    await q.moveToDeadLetter(
      q.all().single.key,
      'PostgrestException 22023: Pilihan tambahan wajib belum dipilih',
    );

    final diagnostic = q.deadLetters().single;
    expect(diagnostic.readableReason, contains('melewati pilihan wajib'));
    expect(diagnostic.clipboardText, contains('Item: Vanilla Latte × 1 · HOT'));
  });

  test(
    'perubahan harga offline diberi diagnosis khusus dan tidak hilang',
    () async {
      await q.enqueue(_payload('stale-price', localReceiptNo: 'OFF-009'));
      await q.moveToDeadLetter(
        q.all().single.key,
        'PostgrestException 22023: Harga item lebih rendah dari harga katalog',
      );

      final diagnostic = q.deadLetters().single;
      expect(diagnostic.localReference, 'OFF-009');
      expect(diagnostic.readableReason, contains('Katalog berubah'));
      expect(diagnostic.readableReason, contains('tetap disimpan'));
      expect(diagnostic.payload['clientOrderId'], 'stale-price');
    },
  );

  test(
    'head-of-line: entri rusak di depan tidak memblok entri valid',
    () async {
      await q.enqueue(_payload('rusak'));
      await q.enqueue(_payload('valid'));
      final first = q.all().first.key;

      // Simulasi: entri pertama ditolak server → dead-letter (bukan break).
      await q.moveToDeadLetter(first, 'ditolak');

      final remaining = q.all();
      expect(remaining.length, 1);
      expect(
        remaining.first.value['clientOrderId'],
        'valid',
        reason:
            'entri valid tetap bisa diproses setelah yang rusak disingkirkan',
      );
    },
  );

  test(
    'retryAllDeadLetters: kembalikan ke antrean aktif & kosongkan dead-letter',
    () async {
      await q.enqueue(_payload('y'));
      final key = q.all().first.key;
      await q.moveToDeadLetter(key, 'gagal');
      expect(q.deadCount.value, 1);
      expect(q.pendingCount.value, 0);

      await q.retryAllDeadLetters();

      expect(q.deadCount.value, 0);
      expect(q.pendingCount.value, 1);
      expect(q.all().first.value['clientOrderId'], 'y');
    },
  );

  test(
    'moveToDeadLetter mempertahankan transaksi jika box tujuan belum siap',
    () async {
      await q.enqueue(_payload('tetap-aman', total: 56000));
      final key = q.all().single.key;
      await Hive.box(OfflineQueueService.deadBoxName).close();

      await q.moveToDeadLetter(key, 'server menolak');

      expect(q.pendingCount.value, 1);
      expect(q.all().single.value['clientOrderId'], 'tetap-aman');
      await Hive.openBox(OfflineQueueService.deadBoxName);
      q.init();
      expect(q.deadCount.value, 0);
    },
  );

  test('retryAllDeadLetters tidak menghapus dead-letter korup', () async {
    await q.enqueue(_payload('valid-retry'));
    final key = q.all().single.key;
    await q.moveToDeadLetter(key, 'gagal');
    await Hive.box(
      OfflineQueueService.deadBoxName,
    ).add('{payload dead-letter rusak');
    q.init();

    await q.retryAllDeadLetters();

    expect(q.pendingCount.value, 1);
    expect(q.all().single.value['clientOrderId'], 'valid-retry');
    expect(q.deadCount.value, 1, reason: 'record korup tidak boleh hilang');
  });

  test('dead-letter korup tetap tampil dengan diagnostik yang jelas', () async {
    await Hive.box(
      OfflineQueueService.deadBoxName,
    ).add('{payload dead-letter rusak');
    q.init();

    final diagnostic = q.deadLetters().single;

    expect(diagnostic.error, contains('Record dead-letter lokal rusak'));
    expect(diagnostic.payload['_offlineDeadRaw'], '{payload dead-letter rusak');
    expect(diagnostic.localReference, 'Tanpa nomor lokal');
  });

  test('retryDeadLetter hanya memulihkan transaksi yang dipilih', () async {
    await q.enqueue(_payload('satu'));
    await q.enqueue(_payload('dua'));
    for (final entry in q.all().toList()) {
      await q.moveToDeadLetter(
        entry.key,
        'ditolak ${entry.value['clientOrderId']}',
      );
    }

    final selected = q.deadLetters().firstWhere(
      (entry) => entry.payload['clientOrderId'] == 'dua',
    );
    expect(await q.retryDeadLetter(selected.key), isTrue);

    expect(q.pendingCount.value, 1);
    expect(q.deadCount.value, 1);
    expect(q.all().single.value['clientOrderId'], 'dua');
    expect(q.deadLetters().single.payload['clientOrderId'], 'satu');
  });

  test('retryDeadLetter menahan payload invalid di dead-letter', () async {
    await q.enqueue(_payload('manual-invalid'));
    final activeKey = q.all().single.key;
    await q.moveToDeadLetter(
      activeKey,
      'ditolak',
      payloadOverride: <String, dynamic>{
        'kind': 'paid',
        'clientOrderId': 'manual-invalid',
      },
    );
    final deadKey = q.deadLetters().single.key;

    expect(await q.retryDeadLetter(deadKey), isFalse);
    expect(q.pendingCount.value, 0);
    expect(q.deadCount.value, 1);
    expect(q.deadLetters().single.payload['clientOrderId'], 'manual-invalid');
  });

  test(
    'retryAllDeadLetters melewati payload invalid tanpa menghapusnya',
    () async {
      await q.enqueue(_payload('massal-valid'));
      await q.enqueue(_payload('massal-invalid'));
      for (final entry in q.all().toList()) {
        await q.moveToDeadLetter(
          entry.key,
          'ditolak',
          payloadOverride: entry.value['clientOrderId'] == 'massal-invalid'
              ? <String, dynamic>{
                  'kind': 'paid',
                  'clientOrderId': 'massal-invalid',
                }
              : null,
        );
      }

      await q.retryAllDeadLetters();

      expect(q.pendingCount.value, 1);
      expect(q.all().single.value['clientOrderId'], 'massal-valid');
      expect(q.deadCount.value, 1);
      expect(q.deadLetters().single.payload['clientOrderId'], 'massal-invalid');
    },
  );

  test('diagnostik dead-letter menampilkan till, waktu, dan split payment', () {
    const diagnostic = DeadLetterDiagnostic(
      key: 1,
      error: 'PostgrestException 22023: Till sudah ditutup',
      failedAt: '2026-07-31T06:15:00.000Z',
      payload: {
        'clientOrderId': 'order-local-1',
        'localReceiptNo': '2R-001',
        'shiftId': 'shift-lama',
        'createdBy': 'kasir-1',
        'createdAt': '2026-07-31T06:10:00.000Z',
        'shiftStartedAt': '2026-07-30T04:00:00.000Z',
        'shiftVerifiedAt': '2026-07-30T04:00:01.000Z',
        'shiftSource': 'cache_offline',
        'payments': [
          {'method': 'cash', 'amount': 10000},
          {'method': 'qris', 'amount': 14000},
        ],
      },
    );

    expect(diagnostic.localReference, '2R-001');
    expect(diagnostic.shiftId, 'shift-lama');
    expect(diagnostic.paymentSummary, contains('cash: 10000'));
    expect(diagnostic.paymentSummary, contains('qris: 14000'));
    expect(diagnostic.readableReason, contains('ditutup di server'));
    expect(diagnostic.clipboardText, contains('ID till: shift-lama'));
    expect(diagnostic.clipboardText, contains('Sumber till: cache_offline'));
  });

  test('payload override menjaga metadata hasil diagnosis terakhir', () async {
    await q.enqueue(_payload('lama')..['shiftId'] = 'shift-lama');
    final key = q.all().single.key;
    await q.moveToDeadLetter(
      key,
      'ditolak',
      payloadOverride: {
        'clientOrderId': 'lama',
        'shiftId': 'shift-baru',
        'originalShiftId': 'shift-lama',
      },
    );

    final dead = q.deadLetters().single;
    expect(dead.shiftId, 'shift-baru');
    expect(dead.originalShiftId, 'shift-lama');
  });

  test('discardDeadLetter: buang permanen satu entri', () async {
    await q.enqueue(_payload('z'));
    final key = q.all().first.key;
    await q.moveToDeadLetter(key, 'gagal');
    final deadKey = q.deadLetters().first.key;

    await q.discardDeadLetter(deadKey);

    expect(q.deadCount.value, 0);
    expect(q.pendingCount.value, 0);
  });

  test('dead-letter auth lama dipulihkan tanpa kehilangan payload', () async {
    await q.enqueue(_payload('auth-1', total: 56000));
    final key = q.all().first.key;
    await q.moveToDeadLetter(key, 'PostgrestException PGRST301: JWT expired');

    final recovered = await q.retryRecoverableDeadLetters();

    expect(recovered, 1);
    expect(q.deadCount.value, 0);
    expect(q.pendingCount.value, 1);
    expect(q.all().single.value['clientOrderId'], 'auth-1');
    expect(q.all().single.value['total'], 56000);
  });

  test('dead-letter auth dengan payload invalid tidak dipulihkan', () async {
    await q.enqueue(_payload('auth-invalid'));
    final key = q.all().single.key;
    await q.moveToDeadLetter(
      key,
      'PostgrestException PGRST301: JWT expired',
      payloadOverride: <String, dynamic>{
        'kind': 'paid',
        'clientOrderId': 'auth-invalid',
      },
    );

    final recovered = await q.retryRecoverableDeadLetters();

    expect(recovered, 0);
    expect(q.pendingCount.value, 0);
    expect(q.deadCount.value, 1);
  });

  test('dead-letter constraint tidak diretry otomatis', () async {
    await q.enqueue(_payload('invalid-1'));
    final key = q.all().first.key;
    await q.moveToDeadLetter(
      key,
      'PostgrestException 23514: melanggar constraint',
    );

    final recovered = await q.retryRecoverableDeadLetters();

    expect(recovered, 0);
    expect(q.deadCount.value, 1);
    expect(q.pendingCount.value, 0);
  });

  test('enqueue menolak payload tidak lengkap tanpa menulis antrean', () async {
    final invalid = _payload('tidak-lengkap')..remove('createdBy');

    expect(
      () => q.enqueue(invalid),
      throwsA(isA<OfflineQueuePayloadException>()),
    );
    expect(q.pendingCount.value, 0);
    expect(q.all(), isEmpty);
  });

  test('enqueue menolak kuantitas pecahan dan subtotal item invalid', () async {
    final fractional = _payload('qty-pecahan');
    (fractional['items'] as List).first['quantity'] = 1.5;
    final missingSubtotal = _payload('subtotal-hilang');
    (missingSubtotal['items'] as List).first.remove('subtotal');

    await expectLater(
      q.enqueue(fractional),
      throwsA(isA<OfflineQueuePayloadException>()),
    );
    await expectLater(
      q.enqueue(missingSubtotal),
      throwsA(isA<OfflineQueuePayloadException>()),
    );
    expect(q.pendingCount.value, 0);
    expect(q.all(), isEmpty);
  });
}

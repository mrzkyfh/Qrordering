import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrordering/shared/services/transaction_journal_service.dart';

void main() {
  late Directory tmp;
  final journal = TransactionJournalService.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('transaction_journal_test');
    Hive.init(tmp.path);
    await Hive.openBox(TransactionJournalService.boxName);
    await Hive.box(TransactionJournalService.boxName).clear();
    journal.init();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('entry remains durable until server confirmation', () async {
    await journal.enqueue(
      id: 'payment-1',
      type: 'existing_payment',
      payload: {'idempotencyKey': 'key-1', 'amount': 10000},
    );
    await journal.markSending('payment-1');
    await journal.markPending('payment-1', 'timeout');

    expect(journal.pendingCount.value, 1);
    expect(journal.get('payment-1')?['payload']['idempotencyKey'], 'key-1');

    await journal.remove('payment-1');
    expect(journal.pendingCount.value, 0);
  });

  test('validation rejection stays visible for manual review', () async {
    await journal.enqueue(
      id: 'split-1',
      type: 'split_payment',
      payload: {'idempotencyKey': 'key-split'},
    );
    await journal.markNeedsReview('split-1', 'nominal tidak sesuai');

    expect(journal.pendingCount.value, 0);
    expect(journal.attentionCount.value, 1);
    expect(journal.get('split-1')?['lastError'], contains('nominal'));

    await journal.retryAllAttention();
    expect(journal.pendingCount.value, 1);
    expect(journal.attentionCount.value, 0);
  });

  test(
    'diagnostik pembayaran memuat referensi, nominal, dan solusi aman',
    () async {
      await journal.enqueue(
        id: 'split-diagnostic-1',
        type: 'split_payment',
        payload: {
          'orderId': 'order-77',
          'outletId': 'outlet-1',
          'shiftId': 'shift-lama',
          'method': 'qris',
          'amount': 56000,
          'expectedUserId': 'kasir-1',
          'idempotencyKey': 'idem-aman-1',
        },
      );
      await journal.markNeedsReview(
        'split-diagnostic-1',
        '22023 Till sudah ditutup',
      );

      final diagnostic = journal.diagnostics(attentionOnly: true).single;
      expect(diagnostic.title, 'Bagian split payment');
      expect(diagnostic.reference, 'order-77');
      expect(diagnostic.amountSummary, 'qris · 56000');
      expect(diagnostic.retryable, isTrue);
      expect(diagnostic.readableReason, contains('Till pada payload'));
      expect(diagnostic.clipboardText, contains('ID till: shift-lama'));
      expect(diagnostic.clipboardText, contains('ID pengguna: kasir-1'));
    },
  );

  test('retry per entri tidak menyentuh transaksi lain', () async {
    for (final id in ['payment-a', 'payment-b']) {
      await journal.enqueue(
        id: id,
        type: 'existing_payment',
        payload: {'orderId': 'order-$id', 'idempotencyKey': 'key-$id'},
      );
      await journal.markNeedsReview(id, 'ditolak server');
    }

    expect(await journal.retryAttention('payment-a'), isTrue);
    expect(journal.get('payment-a')?['status'], 'pending');
    expect(journal.get('payment-b')?['status'], 'needs_review');
    expect(journal.pendingCount.value, 1);
    expect(journal.attentionCount.value, 1);
  });

  test('append item yang perlu ditinjau dapat dicoba ulang', () async {
    await journal.enqueue(
      id: 'append-1',
      type: 'append_order_items',
      payload: {
        'orderId': 'order-1',
        'outletId': 'outlet-1',
        'requestId': 'append-1',
        'items': const [
          {'menu_item_id': 'menu-1', 'quantity': 1, 'unit_price': 10000},
        ],
      },
    );
    await journal.markNeedsReview('append-1', 'server sementara menolak');

    final diagnostic = journal.diagnostics(attentionOnly: true).single;
    expect(diagnostic.retryable, isTrue);
    expect(await journal.retryAttention('append-1'), isTrue);
    expect(journal.get('append-1')?['status'], 'pending');
  });

  test('shift offline yang perlu ditinjau dapat dicoba ulang', () async {
    await journal.enqueue(
      id: 'shift-open-1',
      type: 'shift_open',
      payload: {
        'shiftId': 'shift-1',
        'expectedUserId': 'staff-1',
        'outletId': 'outlet-1',
      },
    );
    await journal.markNeedsReview('shift-open-1', 'shift bentrok di server');

    final diagnostic = journal.diagnostics(attentionOnly: true).single;
    expect(diagnostic.retryable, isTrue);
    expect(await journal.retryAttention('shift-open-1'), isTrue);
    expect(journal.get('shift-open-1')?['status'], 'pending');
  });

  test('retry massal mencakup shift offline idempoten', () async {
    await journal.enqueue(
      id: 'shift-open-bulk',
      type: 'shift_open',
      payload: {'shiftId': 'shift-bulk', 'expectedUserId': 'staff-1'},
    );
    await journal.markNeedsReview('shift-open-bulk', 'respons sementara');

    await journal.retryAllAttention();

    expect(journal.get('shift-open-bulk')?['status'], 'pending');
    expect(journal.attentionCount.value, 0);
  });

  test('void/refund tanpa idempotency tidak dapat diretry otomatis', () async {
    await journal.enqueue(
      id: 'manual-void-1',
      type: 'manual_review',
      payload: {
        'operation': 'void_order',
        'orderId': 'order-1',
        'reason': 'salah input',
        'requiresPinWhenOnline': true,
      },
    );
    await journal.markNeedsReview(
      'manual-void-1',
      'Menunggu verifikasi PIN saat online',
    );

    final diagnostic = journal.diagnostics(attentionOnly: true).single;
    expect(diagnostic.title, 'Void order perlu verifikasi');
    expect(diagnostic.retryable, isFalse);
    expect(diagnostic.guidance, contains('Buka detail order'));
    expect(diagnostic.clipboardText.toLowerCase(), isNot(contains('pin:')));
    expect(await journal.retryAttention('manual-void-1'), isFalse);
    expect(journal.get('manual-void-1')?['status'], 'needs_review');
  });

  test('kas offline ber-request-id dapat diretry otomatis', () async {
    await journal.enqueue(
      id: 'cash-movement-1',
      type: 'cash_movement',
      payload: {
        'requestId': 'request-1',
        'shiftId': 'shift-1',
        'outletId': 'outlet-1',
        'expectedUserId': 'manager-1',
        'type': 'out',
        'amount': 5000,
        'createdAt': '2026-10-03T01:00:00Z',
      },
    );
    await journal.markNeedsReview('cash-movement-1', 'respons terputus');

    final diagnostic = journal.diagnostics(attentionOnly: true).single;
    expect(diagnostic.title, 'Kas masuk/keluar offline');
    expect(diagnostic.retryable, isTrue);
    expect(await journal.retryAttention('cash-movement-1'), isTrue);
    expect(journal.get('cash-movement-1')?['status'], 'pending');
  });

  test('payload rusak tetap terlihat dan dihitung perlu pemeriksaan', () async {
    await Hive.box(
      TransactionJournalService.boxName,
    ).put('journal-terpotong', '{json-terpotong');
    journal.init();

    expect(journal.pendingCount.value, 0);
    expect(journal.attentionCount.value, 1);
    final diagnostic = journal.diagnostics(attentionOnly: true).single;
    expect(diagnostic.isCorrupt, isTrue);
    expect(diagnostic.id, 'journal-terpotong');
    expect(diagnostic.readableReason, contains('tidak dapat dibaca'));
    expect(await journal.retryAttention(diagnostic.id), isFalse);
  });

  test(
    'sending entries are recovered to pending after process restart',
    () async {
      await journal.enqueue(
        id: 'payment-crash',
        type: 'existing_payment',
        payload: {'idempotencyKey': 'key-crash'},
      );
      await journal.markSending('payment-crash');
      journal.init();

      expect(journal.get('payment-crash')?['status'], 'pending');
    },
  );

  test('restart nyata mempertahankan entri yang perlu ditinjau', () async {
    await journal.enqueue(
      id: 'payment-after-restart',
      type: 'existing_payment',
      payload: {'orderId': 'order-restart', 'idempotencyKey': 'key-restart'},
    );
    await journal.markNeedsReview(
      'payment-after-restart',
      'server menolak nominal',
    );

    await Hive.box(TransactionJournalService.boxName).close();
    await Hive.openBox(TransactionJournalService.boxName);
    journal.init();

    expect(journal.attentionCount.value, 1);
    expect(
      journal.diagnostics(attentionOnly: true).single.orderId,
      'order-restart',
    );
  });

  test(
    'manual review dibersihkan setelah aksi yang sama berhasil online',
    () async {
      Future<void> add(
        String id,
        String operation,
        String orderId, {
        List<Map<String, dynamic>>? items,
      }) async {
        final payload = <String, dynamic>{
          'operation': operation,
          'orderId': orderId,
          'items': ?items,
        };
        await journal.enqueue(id: id, type: 'manual_review', payload: payload);
        await journal.markNeedsReview(id, 'menunggu PIN');
      }

      const selected = [
        {'order_item_id': 'item-1', 'qty': 1},
        {'order_item_id': 'item-2', 'qty': 2},
      ];
      await add('match', 'void_order_items', 'order-1', items: selected);
      await add(
        'different-items',
        'void_order_items',
        'order-1',
        items: const [
          {'order_item_id': 'item-3', 'qty': 1},
        ],
      );
      await add('different-operation', 'refund_order', 'order-1');

      final removed = await journal.resolveManualReviews(
        operation: 'void_order_items',
        orderId: 'order-1',
        // Urutan berbeda tetap dianggap pilihan item yang sama.
        items: selected.reversed.toList(),
      );

      expect(removed, 1);
      expect(journal.get('match'), isNull);
      expect(journal.get('different-items'), isNotNull);
      expect(journal.get('different-operation'), isNotNull);
      expect(journal.attentionCount.value, 2);
    },
  );

  test('resolusi void penuh membersihkan semua permintaan order itu', () async {
    for (final id in ['void-a', 'void-b']) {
      await journal.enqueue(
        id: id,
        type: 'manual_review',
        payload: {'operation': 'void_order', 'orderId': 'order-1'},
      );
      await journal.markNeedsReview(id, 'menunggu PIN');
    }

    final removed = await journal.resolveManualReviews(
      operation: 'void_order',
      orderId: 'order-1',
    );

    expect(removed, 2);
    expect(journal.attentionCount.value, 0);
  });
}

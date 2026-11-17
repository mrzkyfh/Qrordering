import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/data/datasources/shift_datasource.dart';
import 'package:time420s/shared/services/connectivity_service.dart';
import 'package:time420s/shared/services/offline_queue_service.dart';
import 'package:time420s/shared/services/transaction_journal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('offline_shift_close_test');
    Hive.init(temp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await Hive.openBox(OfflineQueueService.boxName);
    await Hive.openBox(OfflineQueueService.deadBoxName);
    await Hive.openBox(TransactionJournalService.boxName);
    OfflineQueueService.instance.init();
    TransactionJournalService.instance.init();
    ConnectivityService.instance.online.value = false;

    final box = Hive.box(PosDatasource.menuCacheBoxName);
    await box.put(
      'open_shifts_outlet-1',
      jsonEncode([
        {
          'id': 'shift-offline',
          'kasir_id': 'kasir-1',
          'kasir_name': 'Siti',
          'start_time': '2026-10-03T01:00:00.000Z',
          'opening_cash': 100000,
          'verified_at': DateTime.now().toUtc().toIso8601String(),
        },
      ]),
    );
    await box.put(
      'receipt_outlet_outlet-1',
      jsonEncode({'name': 'Time 420s', 'settings': <String, dynamic>{}}),
    );
    await box.put('orders_active_outlet-1', jsonEncode(const []));
    await box.put('orders_completed_outlet-1', jsonEncode(const []));
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await Hive.deleteFromDisk();
    await temp.delete(recursive: true);
  });

  test(
    'tutup kasir offline disimpan dan menghasilkan laporan sementara',
    () async {
      final report = await ShiftDatasource().closeShift(
        shiftId: 'shift-offline',
        closingCash: 100000,
        notes: 'Internet putus',
      );

      expect(report.isProvisional, isTrue);
      expect(report.shiftId, 'shift-offline');
      expect(report.cashDifference, 0);
      final entry = TransactionJournalService.instance.get(
        'shift-close-shift-offline',
      );
      expect(entry?['type'], 'shift_close');
      expect((entry?['payload'] as Map)['closingCash'], 100000);
      expect(PosDatasource().cachedShiftSnapshotById('shift-offline'), isNull);
    },
  );

  test('shift baru ditahan sampai penutupan offline tersinkron', () async {
    await ShiftDatasource().closeShift(
      shiftId: 'shift-offline',
      closingCash: 100000,
    );

    await expectLater(
      ShiftDatasource().openShift('outlet-1', 'kasir-1', 50000),
      throwsA(isA<PendingShiftCloseException>()),
    );
  });
}

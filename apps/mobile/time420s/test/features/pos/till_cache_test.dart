import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/data/datasources/shift_datasource.dart';
import 'package:time420s/shared/services/connectivity_service.dart';
import 'package:time420s/shared/services/transaction_journal_service.dart';

/// Sejak "cetak dulu, sinkron belakangan", shift order ditentukan dari CACHE —
/// menunggu jaringan di titik itu menggagalkan target struk 0.1 detik.
///
/// Yang dijaga di sini: pembacaan cache benar-benar tanpa backend, dan kasir
/// selalu dapat shift-nya sendiri walau ada beberapa till terbuka. Salah di
/// sini = kas nempel ke laci orang lain / laporan per-shift bolong.
void main() {
  late Directory tmp;
  final ds = PosDatasource();
  const outletId = 'outlet-1';

  Future<void> seedOpenShifts(List<Map<String, dynamic>> shifts) async {
    final verifiedAt = DateTime.now().toUtc().toIso8601String();
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'open_shifts_$outletId',
      jsonEncode([
        for (final shift in shifts)
          {...shift, 'verified_at': shift['verified_at'] ?? verifiedAt},
      ]),
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('till_cache_test');
    Hive.init(tmp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await Hive.openBox(TransactionJournalService.boxName);
    await Hive.box(PosDatasource.menuCacheBoxName).clear();
    await Hive.box(TransactionJournalService.boxName).clear();
    TransactionJournalService.instance.init();
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('cache kosong → tak ada shift, tanpa menyentuh Supabase', () {
    // Supabase sengaja TIDAK diinisialisasi: jalur cetak harus tetap hidup.
    expect(ds.cachedOpenShifts(outletId), isEmpty);
    expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), isNull);
  });

  test(
    'kasir dapat shift miliknya sendiri walau ada till lain terbuka',
    () async {
      await seedOpenShifts([
        {'id': 'shift-owner', 'kasir_id': 'owner-9', 'kasir_name': 'Owner'},
        {'id': 'shift-mine', 'kasir_id': 'kasir-1', 'kasir_name': 'Andi'},
      ]);

      expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), 'shift-mine');
    },
  );

  test('staf tanpa shift terbuka → null (bukan till orang lain)', () async {
    await seedOpenShifts([
      {'id': 'shift-lain', 'kasir_id': 'kasir-2', 'kasir_name': 'Budi'},
    ]);

    expect(
      ds.cachedOwnShiftId(outletId, 'kasir-1'),
      isNull,
      reason: 'jangan pernah menebak till milik kasir lain',
    );
  });

  test('cache rusak → dianggap kosong, tidak melempar', () async {
    await Hive.box(
      PosDatasource.menuCacheBoxName,
    ).put('open_shifts_$outletId', 'bukan-json');

    expect(ds.cachedOpenShifts(outletId), isEmpty);
    expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), isNull);
  });

  test(
    'cache shift yang sudah lama tidak dipercaya untuk transaksi baru',
    () async {
      final now = DateTime.utc(2026, 8, 4, 8);
      await seedOpenShifts([
        {
          'id': 'shift-lama',
          'kasir_id': 'kasir-1',
          'verified_at': now
              .subtract(const Duration(hours: 73))
              .toIso8601String(),
        },
      ]);

      expect(ds.cachedOpenShifts(outletId, now: now), isEmpty);
    },
  );

  test(
    'shift aktif yang baru dimuat tetap tersedia saat perangkat offline',
    () async {
      await seedOpenShifts([
        {'id': 'shift-lain', 'kasir_id': 'kasir-2', 'kasir_name': 'Budi'},
      ]);

      await ds.rememberOpenShift(
        outletId: outletId,
        shiftId: 'shift-mine',
        kasirId: 'kasir-1',
        kasirName: 'Andi',
        startTime: DateTime.utc(2026, 7, 30, 8),
        openingCash: 125000,
      );

      expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), 'shift-mine');
      expect(
        ds.cachedOwnShiftId(outletId, 'kasir-2'),
        'shift-lain',
        reason: 'menyimpan shift sendiri tidak boleh menghapus till lain',
      );
      final snapshot = ds.cachedShiftSnapshot(outletId, 'shift-mine');
      expect(snapshot?['start_time'], '2026-07-30T08:00:00.000Z');
      expect(snapshot?['verified_at'], isNotNull);
      expect(snapshot?['opening_cash'], 125000);
    },
  );

  test('shift aktif dapat dibaca penuh saat Supabase offline', () async {
    await ds.rememberOpenShift(
      outletId: outletId,
      shiftId: 'shift-mine',
      kasirId: 'kasir-1',
      kasirName: 'Andi',
      startTime: DateTime.utc(2026, 7, 30, 8),
      openingCash: 125000,
    );
    ConnectivityService.instance.online.value = false;

    final shift = await ShiftDatasource().fetchActiveShift(outletId, 'kasir-1');

    expect(shift?.id, 'shift-mine');
    expect(shift?.openingCash, 125000);
    expect(shift?.cashierName, 'Andi');
  });

  test('shift baru dapat dibuka offline dan aman di jurnal', () async {
    ConnectivityService.instance.online.value = false;

    final shift = await ShiftDatasource().openShift(
      outletId,
      'kasir-1',
      175000,
    );

    expect(shift.outletId, outletId);
    expect(shift.kasirId, 'kasir-1');
    expect(shift.openingCash, 175000);
    expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), shift.id);
    final entry = TransactionJournalService.instance.all().singleWhere(
      (value) => value['type'] == 'shift_open',
    );
    final payload = (entry['payload'] as Map).cast<String, dynamic>();
    expect(payload['shiftId'], shift.id);
    expect(payload['expectedUserId'], 'kasir-1');
    expect(payload['openingCash'], 175000);
  });

  test(
    'shift baru kasir menggantikan ID cache sesi lama kasir yang sama',
    () async {
      await seedOpenShifts([
        {
          'id': 'shift-lama',
          'kasir_id': 'kasir-1',
          'kasir_name': 'Andi',
          'start_time': '2026-07-28T08:00:00.000Z',
        },
        {'id': 'shift-lain', 'kasir_id': 'kasir-2', 'kasir_name': 'Budi'},
      ]);

      await ds.rememberOpenShift(
        outletId: outletId,
        shiftId: 'shift-baru',
        kasirId: 'kasir-1',
        kasirName: 'Andi',
        startTime: DateTime.utc(2026, 7, 30, 8),
        verifiedAt: DateTime.now().toUtc(),
      );

      expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), 'shift-baru');
      expect(ds.cachedShiftSnapshot(outletId, 'shift-lama'), isNull);
      expect(
        ds.cachedShiftSnapshot(outletId, 'shift-baru')?['verified_at'],
        isNotNull,
      );
      expect(ds.cachedOwnShiftId(outletId, 'kasir-2'), 'shift-lain');
    },
  );

  test('shift yang ditutup dihapus tanpa menghapus till kasir lain', () async {
    await seedOpenShifts([
      {'id': 'shift-mine', 'kasir_id': 'kasir-1', 'kasir_name': 'Andi'},
      {'id': 'shift-lain', 'kasir_id': 'kasir-2', 'kasir_name': 'Budi'},
    ]);

    await ds.forgetOpenShift(
      outletId: outletId,
      shiftId: 'shift-mine',
      kasirId: 'kasir-1',
    );

    expect(ds.cachedOwnShiftId(outletId, 'kasir-1'), isNull);
    expect(ds.cachedOwnShiftId(outletId, 'kasir-2'), 'shift-lain');
  });

  test(
    'cache outlet & kategori rusak/kosong → null & kosong, tidak melempar',
    () async {
      expect(ds.cachedOutletReceiptMap(outletId), isNull);
      expect(ds.cachedCategoryNames(outletId), isEmpty);

      await Hive.box(
        PosDatasource.menuCacheBoxName,
      ).put('receipt_outlet_$outletId', '{{');
      await Hive.box(
        PosDatasource.menuCacheBoxName,
      ).put('catnames_$outletId', '{{');

      expect(ds.cachedOutletReceiptMap(outletId), isNull);
      expect(ds.cachedCategoryNames(outletId), isEmpty);
    },
  );

  test('cache setting dan kategori menghormati batas usia', () async {
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    await box.put(
      'settings_$outletId',
      jsonEncode({'kitchen_print_mode': 'split'}),
    );
    await box.put(
      'settings_${outletId}_cached_at',
      DateTime.now().toUtc().toIso8601String(),
    );
    await box.put('catnames_$outletId', jsonEncode({'cat-1': 'KEBAB'}));
    await box.put(
      'catnames_${outletId}_cached_at',
      DateTime.now().toUtc().toIso8601String(),
    );

    expect(
      ds.cachedOutletSettings(outletId, maxAge: const Duration(minutes: 10)),
      containsPair('kitchen_print_mode', 'split'),
    );
    expect(
      ds.cachedCategoryNames(outletId, maxAge: const Duration(minutes: 10)),
      {'cat-1': 'KEBAB'},
    );

    final expired = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 11))
        .toIso8601String();
    await box.put('settings_${outletId}_cached_at', expired);
    await box.put('catnames_${outletId}_cached_at', expired);

    expect(
      ds.cachedOutletSettings(outletId, maxAge: const Duration(minutes: 10)),
      isNull,
    );
    expect(
      ds.cachedCategoryNames(outletId, maxAge: const Duration(minutes: 10)),
      isEmpty,
    );
    // Mode offline tetap boleh meminta cache lama secara eksplisit.
    expect(ds.cachedOutletSettings(outletId), isNotNull);
    expect(ds.cachedCategoryNames(outletId), {'cat-1': 'KEBAB'});
  });
}

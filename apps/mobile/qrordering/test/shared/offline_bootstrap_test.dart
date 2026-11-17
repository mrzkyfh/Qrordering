import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';
import 'package:qrordering/shared/services/connectivity_service.dart';
import 'package:qrordering/shared/services/offline_bootstrap_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  Future<void> putCompleteBundle(String outletId) async {
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    for (final key in [
      'cat_$outletId',
      'item_$outletId',
      'open_shifts_$outletId',
      'orders_active_$outletId',
      'orders_completed_$outletId',
      'tables_$outletId',
      'clockin_staff_$outletId',
    ]) {
      await box.put(key, jsonEncode(const []));
    }
    for (final key in [
      'settings_$outletId',
      'receipt_outlet_$outletId',
      'catnames_$outletId',
    ]) {
      await box.put(key, jsonEncode(const {}));
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('offline_bootstrap_test');
    Hive.init(tmp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    ConnectivityService.instance.online.value = false;
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test(
    'offline pertama ditolak bila bundle cabang belum pernah diunduh',
    () async {
      final ready = await OfflineBootstrapService.instance.prepare(
        'outlet-baru',
      );

      expect(ready, isFalse);
      expect(
        OfflineBootstrapService.instance.state.value.phase,
        OfflineBootstrapPhase.failed,
      );
    },
  );

  test('bundle lama membuat cabang langsung siap saat internet mati', () async {
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    await putCompleteBundle('outlet-1');
    await box.put('offline_bundle_ready_outlet-1', true);
    await box.put(
      'offline_bundle_synced_at_outlet-1',
      '2026-10-01T03:00:00.000Z',
    );

    final ready = await OfflineBootstrapService.instance.prepare('outlet-1');

    expect(ready, isTrue);
    expect(OfflineBootstrapService.instance.isReady('outlet-1'), isTrue);
    expect(
      OfflineBootstrapService.instance.state.value.phase,
      OfflineBootstrapPhase.cacheOnly,
    );
    expect(
      OfflineBootstrapService.instance.lastSyncedAt('outlet-1'),
      isNotNull,
    );
  });

  test('marker siap ditolak bila salah satu cache inti hilang', () async {
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    await putCompleteBundle('outlet-1');
    await box.put('offline_bundle_ready_outlet-1', true);
    await box.delete('item_outlet-1');

    expect(OfflineBootstrapService.instance.isReady('outlet-1'), isFalse);
    expect(await OfflineBootstrapService.instance.prepare('outlet-1'), isFalse);
  });

  test('cache JSON korup tidak pernah dianggap siap offline', () async {
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    await putCompleteBundle('outlet-1');
    await box.put('offline_bundle_ready_outlet-1', true);
    await box.put('tables_outlet-1', '{terpotong');

    expect(OfflineBootstrapService.instance.isReady('outlet-1'), isFalse);
  });
}

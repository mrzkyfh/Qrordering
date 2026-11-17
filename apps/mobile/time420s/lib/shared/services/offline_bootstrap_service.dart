import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/orders/data/datasources/orders_datasource.dart';
import '../../features/pos/data/datasources/pos_datasource.dart';
import 'connectivity_service.dart';

enum OfflineBootstrapPhase { idle, downloading, ready, cacheOnly, failed }

class OfflineBootstrapState {
  final OfflineBootstrapPhase phase;
  final String? outletId;
  final DateTime? syncedAt;
  final String? error;

  const OfflineBootstrapState({
    this.phase = OfflineBootstrapPhase.idle,
    this.outletId,
    this.syncedAt,
    this.error,
  });

  bool get ready =>
      phase == OfflineBootstrapPhase.ready ||
      phase == OfflineBootstrapPhase.cacheOnly;
}

/// Mengunduh snapshot operasional cabang sebelum POS dipakai dan menyimpan
/// penanda kesiapan offline. Transaksi tetap memakai outbox/jurnal terpisah.
class OfflineBootstrapService {
  OfflineBootstrapService._();
  static final OfflineBootstrapService instance = OfflineBootstrapService._();

  static const _readyPrefix = 'offline_bundle_ready_';
  static const _syncedAtPrefix = 'offline_bundle_synced_at_';

  final ValueNotifier<OfflineBootstrapState> state =
      ValueNotifier<OfflineBootstrapState>(const OfflineBootstrapState());
  final Map<String, Future<bool>> _inFlight = {};

  Box? get _box => Hive.isBoxOpen(PosDatasource.menuCacheBoxName)
      ? Hive.box(PosDatasource.menuCacheBoxName)
      : null;

  bool isReady(String outletId) {
    final box = _box;
    if (box == null ||
        box.get('$_readyPrefix$outletId', defaultValue: false) != true) {
      return false;
    }
    // Marker saja tidak cukup: file cache bisa terhapus/korup setelah update,
    // storage pressure, atau proses mati di tengah unduhan. Jangan izinkan
    // clock-in offline bila satu komponen inti tidak dapat dibaca.
    final listKeys = [
      'cat_$outletId',
      'item_$outletId',
      'open_shifts_$outletId',
      'orders_active_$outletId',
      'orders_completed_$outletId',
      'tables_$outletId',
      'clockin_staff_$outletId',
    ];
    final mapKeys = [
      'settings_$outletId',
      'receipt_outlet_$outletId',
      'catnames_$outletId',
    ];
    try {
      for (final key in listKeys) {
        if (jsonDecode(box.get(key) as String) is! List) return false;
      }
      for (final key in mapKeys) {
        if (jsonDecode(box.get(key) as String) is! Map) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  DateTime? lastSyncedAt(String outletId) {
    final raw = _box?.get('$_syncedAtPrefix$outletId') as String?;
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  Future<bool> prepare(String outletId, {bool force = false}) {
    if (outletId.isEmpty) return Future.value(false);
    final running = _inFlight[outletId];
    if (running != null) return running;
    final future = _prepare(outletId, force: force);
    _inFlight[outletId] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[outletId], future)) _inFlight.remove(outletId);
    });
  }

  Future<bool> _prepare(String outletId, {required bool force}) async {
    final cachedAt = lastSyncedAt(outletId);
    if (!ConnectivityService.instance.online.value) {
      final cached = isReady(outletId);
      state.value = OfflineBootstrapState(
        phase: cached
            ? OfflineBootstrapPhase.cacheOnly
            : OfflineBootstrapPhase.failed,
        outletId: outletId,
        syncedAt: cachedAt,
        error: cached ? null : 'Data cabang belum pernah diunduh',
      );
      return cached;
    }
    if (!force &&
        isReady(outletId) &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 5)) {
      state.value = OfflineBootstrapState(
        phase: OfflineBootstrapPhase.ready,
        outletId: outletId,
        syncedAt: cachedAt,
      );
      return true;
    }

    state.value = OfflineBootstrapState(
      phase: OfflineBootstrapPhase.downloading,
      outletId: outletId,
      syncedAt: cachedAt,
    );
    try {
      final pos = PosDatasource();
      final orders = OrdersDatasource();
      await Future.wait([
        pos.fetchCategories(outletId),
        pos.fetchMenuItems(outletId),
        pos.fetchOutletSettings(outletId),
        pos.fetchOutletReceiptMap(outletId),
        pos.fetchCategoryNames(outletId),
        pos.fetchOpenShifts(outletId),
        orders.fetchActiveOrders(outletId),
        orders.fetchCompletedOrders(outletId),
        orders.fetchTables(outletId),
        _fetchClockinStaff(outletId),
      ]).timeout(const Duration(seconds: 25));

      // Semua fetch di atas wajib menghasilkan snapshot yang dapat dibaca.
      // Beberapa datasource sengaja mengembalikan nilai kosong saat gagal;
      // validasi ini mencegah marker siap palsu pada instalasi pertama.
      await _box?.put('$_readyPrefix$outletId', true);
      if (!isReady(outletId)) {
        await _box?.delete('$_readyPrefix$outletId');
        throw StateError('Paket offline cabang belum lengkap');
      }

      final syncedAt = DateTime.now().toUtc();
      await _box?.put('$_syncedAtPrefix$outletId', syncedAt.toIso8601String());
      state.value = OfflineBootstrapState(
        phase: OfflineBootstrapPhase.ready,
        outletId: outletId,
        syncedAt: syncedAt.toLocal(),
      );
      return true;
    } catch (error) {
      final cached = isReady(outletId);
      state.value = OfflineBootstrapState(
        phase: cached
            ? OfflineBootstrapPhase.cacheOnly
            : OfflineBootstrapPhase.failed,
        outletId: outletId,
        syncedAt: lastSyncedAt(outletId),
        error: error.toString(),
      );
      return cached;
    }
  }

  Future<void> _fetchClockinStaff(String outletId) async {
    final rows = await Supabase.instance.client.rpc(
      'list_clockin_staff',
      params: {'p_outlet': outletId},
    );
    final staff = (rows as List)
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    await _box?.put('clockin_staff_$outletId', jsonEncode(staff));
  }
}

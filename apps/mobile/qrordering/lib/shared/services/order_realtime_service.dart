import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef OrderRows = List<Map<String, dynamic>>;
typedef OrderRowsSourceFactory =
    Stream<OrderRows> Function(
      String outletId,
      ValueChanged<bool> onStatusChanged,
    );

/// Satu sumber Realtime `orders` yang dipakai bersama oleh notifikasi, badge,
/// dan halaman daftar order.
///
/// Satu channel Broadcast menerima sinyal trigger database hanya ketika order
/// berubah. Snapshot REST kemudian dibagi ke semua konsumen pada perangkat,
/// sehingga tidak ada polling WAL dan tidak ada query ganda per widget.
class OrderRealtimeService {
  OrderRealtimeService({OrderRowsSourceFactory? sourceFactory})
    : _sourceFactory = sourceFactory ?? _defaultSource;

  static final OrderRealtimeService instance = OrderRealtimeService();

  final OrderRowsSourceFactory _sourceFactory;
  final Map<String, _SharedOrderFeed> _feeds = {};

  Stream<OrderRows> watch(String outletId) {
    if (outletId.isEmpty) return Stream.value(const <Map<String, dynamic>>[]);
    return (_feeds[outletId] ??= _SharedOrderFeed(
      outletId: outletId,
      sourceFactory: _sourceFactory,
    )).stream;
  }

  /// Status ini dipakai polling background untuk memilih interval aman.
  bool isHealthy(String outletId) => _feeds[outletId]?.healthy ?? false;

  @visibleForTesting
  int get feedCount => _feeds.length;

  Future<void> dispose() async {
    final feeds = _feeds.values.toList();
    _feeds.clear();
    await Future.wait(feeds.map((feed) => feed.dispose()));
  }

  static Stream<OrderRows> _defaultSource(
    String outletId,
    ValueChanged<bool> onStatusChanged,
  ) {
    final client = Supabase.instance.client;
    RealtimeChannel? channel;
    Timer? refreshTimer;
    var fetching = false;
    var refreshPending = false;
    var subscribed = false;
    var retryAttempt = 0;
    late final StreamController<OrderRows> controller;
    late final Future<void> Function() refreshSnapshot;

    void scheduleRefresh({bool isRetry = false, bool immediate = false}) {
      if (controller.isClosed || !subscribed) return;
      refreshTimer?.cancel();
      final delay = immediate
          ? Duration.zero
          : isRetry
          ? orderSnapshotRetryDelay(retryAttempt)
          : const Duration(milliseconds: 250);
      if (isRetry) retryAttempt++;
      refreshTimer = Timer(delay, () {
        refreshTimer = null;
        unawaited(refreshSnapshot());
      });
    }

    refreshSnapshot = () async {
      if (fetching) {
        refreshPending = true;
        return;
      }
      fetching = true;
      try {
        do {
          refreshPending = false;
          final rows = await client
              .from('orders')
              .select(
                'id, outlet_id, order_type, status, created_at, updated_at, '
                'order_number, table_id, total_amount',
              )
              .eq('outlet_id', outletId)
              .order('created_at', ascending: false)
              .limit(200);
          if (!controller.isClosed) {
            controller.add(List<Map<String, dynamic>>.from(rows));
            onStatusChanged(true);
            retryAttempt = 0;
          }
        } while (refreshPending && !controller.isClosed);
      } catch (error, stack) {
        onStatusChanged(false);
        if (!controller.isClosed) controller.addError(error, stack);
        scheduleRefresh(isRetry: true);
      } finally {
        fetching = false;
      }
    };

    controller = StreamController<OrderRows>(
      onListen: () {
        channel = client
            .channel(
              'orders:$outletId',
              opts: const RealtimeChannelConfig(private: true),
            )
            .onBroadcast(
              event: 'change',
              // Beberapa update status dapat terjadi berdekatan. Debounce kecil
              // menjaga satu gelombang transaksi hanya mengambil satu snapshot.
              callback: (_) => scheduleRefresh(),
            )
            .subscribe((status, error) {
              subscribed = status == RealtimeSubscribeStatus.subscribed;
              onStatusChanged(subscribed);
              // Ambil snapshot sesudah channel benar-benar aktif. Ini menutup
              // celah event yang mungkin terlewat saat koneksi awal maupun
              // setelah Realtime tersambung kembali, tanpa polling berkala.
              if (subscribed) {
                retryAttempt = 0;
                scheduleRefresh(immediate: true);
              } else {
                refreshTimer?.cancel();
                refreshTimer = null;
              }
              if (error != null) {
                debugPrint('OrderBroadcast[$outletId]: $error');
              }
            });
        // Snapshot pertama diambil saat status subscribed. Berikutnya hanya
        // ketika trigger mengirim event atau channel tersambung kembali.
      },
      onCancel: () async {
        subscribed = false;
        refreshTimer?.cancel();
        refreshTimer = null;
        onStatusChanged(false);
        final active = channel;
        channel = null;
        if (active != null) await client.removeChannel(active);
      },
    );
    return controller.stream;
  }
}

@visibleForTesting
Duration orderSnapshotRetryDelay(int attempt) {
  final exponent = attempt.clamp(0, 4);
  return Duration(seconds: 3 * (1 << exponent));
}

class _SharedOrderFeed {
  _SharedOrderFeed({required this.outletId, required this.sourceFactory}) {
    stream = Stream<OrderRows>.multi((listener) {
      if (_disposed) {
        listener.close();
        return;
      }
      _listeners.add(listener);
      final latest = _latest;
      if (latest != null) listener.add(latest);
      if (_listeners.length == 1) _start();
      listener.onCancel = () async {
        _listeners.remove(listener);
        if (_listeners.isEmpty) await _stop();
      };
    }, isBroadcast: true);
  }

  final String outletId;
  final OrderRowsSourceFactory sourceFactory;
  late final Stream<OrderRows> stream;
  final Set<MultiStreamController<OrderRows>> _listeners = {};
  StreamSubscription<OrderRows>? _upstream;
  OrderRows? _latest;
  int _generation = 0;
  bool healthy = false;
  bool _disposed = false;

  void _start() {
    if (_upstream != null || _disposed) return;
    final generation = ++_generation;
    final source = sourceFactory(outletId, (connected) {
      if (generation != _generation) return;
      healthy = connected;
    });
    _upstream = source.listen(
      (rows) {
        if (generation == _generation && !_disposed) {
          _latest = rows;
          for (final listener in _listeners.toList()) {
            listener.add(rows);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _generation || _disposed) return;
        healthy = false;
        debugPrint('OrderRealtimeService[$outletId]: $error');
      },
      onDone: () {
        if (generation != _generation) return;
        healthy = false;
        _upstream = null;
      },
    );
  }

  Future<void> _stop() async {
    healthy = false;
    _generation++;
    final previous = _upstream;
    _upstream = null;
    await previous?.cancel();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _stop();
    for (final listener in _listeners.toList()) {
      listener.close();
    }
    _listeners.clear();
  }
}

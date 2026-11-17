import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/services/order_realtime_service.dart';

void main() {
  test('retry snapshot memakai backoff dan memiliki batas maksimum', () {
    expect(orderSnapshotRetryDelay(0), const Duration(seconds: 3));
    expect(orderSnapshotRetryDelay(1), const Duration(seconds: 6));
    expect(orderSnapshotRetryDelay(4), const Duration(seconds: 48));
    expect(orderSnapshotRetryDelay(20), const Duration(seconds: 48));
  });

  test('beberapa konsumen outlet memakai satu subscription upstream', () async {
    final sources = <StreamController<OrderRows>>[];
    final healthCallbacks = <ValueChanged<bool>>[];
    var factoryCalls = 0;
    final service = OrderRealtimeService(
      sourceFactory: (outletId, onStatusChanged) {
        factoryCalls++;
        expect(outletId, 'outlet-1');
        healthCallbacks.add(onStatusChanged);
        final source = StreamController<OrderRows>();
        sources.add(source);
        return source.stream;
      },
    );
    addTearDown(() async {
      await service.dispose();
      for (final source in sources) {
        if (!source.isClosed) await source.close();
      }
    });

    final firstRows = <OrderRows>[];
    final secondRows = <OrderRows>[];
    final first = service.watch('outlet-1').listen(firstRows.add);
    final second = service.watch('outlet-1').listen(secondRows.add);
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(sources.single.hasListener, isTrue);

    healthCallbacks.single(true);
    expect(service.isHealthy('outlet-1'), isTrue);

    final snapshot = <Map<String, dynamic>>[
      {'id': 'order-1', 'status': 'draft'},
    ];
    sources.single.add(snapshot);
    await pumpEventQueue();
    expect(firstRows, [snapshot]);
    expect(secondRows, [snapshot]);

    final lateRows = <OrderRows>[];
    final lateListener = service.watch('outlet-1').listen(lateRows.add);
    await pumpEventQueue();
    expect(lateRows, [
      snapshot,
    ], reason: 'konsumen baru menerima snapshot akhir');
    expect(factoryCalls, 1);

    await first.cancel();
    expect(sources.single.hasListener, isTrue);
    await second.cancel();
    expect(sources.single.hasListener, isTrue);
    await lateListener.cancel();
    await pumpEventQueue();
    expect(sources.single.hasListener, isFalse);
    expect(service.isHealthy('outlet-1'), isFalse);

    // Setelah semua konsumen pergi, listener berikutnya membuat tepat satu
    // upstream baru, bukan menggunakan subscription yang sudah dibatalkan.
    final third = service.watch('outlet-1').listen((_) {});
    await pumpEventQueue();
    expect(factoryCalls, 2);
    await third.cancel();
  });
}

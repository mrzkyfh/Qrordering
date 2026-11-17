import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/services/backend_route_resolver.dart';

void main() {
  const reachable = BackendProbeResult(reachable: true, latencyMs: 120);
  const blocked = BackendProbeResult(
    reachable: false,
    error: 'Alamat server tidak dapat dijangkau',
  );

  test('jalur langsung diprioritaskan ketika kedua alamat sehat', () async {
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example/',
      fallbackUrl: 'https://fallback.example/',
      anonKey: 'anon',
      probe: (url, _) async => reachable,
    );

    expect(selection.kind, BackendRouteKind.direct);
    expect(selection.url, 'https://primary.example');
    expect(selection.usingFallback, isFalse);
  });

  test('direct sehat tidak menunggu probe gateway yang macet', () async {
    final gatewayNeverFinishes = Completer<BackendProbeResult>();
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example',
      fallbackUrl: 'https://fallback.example',
      anonKey: 'anon',
      probe: (url, _) => url.contains('primary')
          ? Future.value(reachable)
          : gatewayNeverFinishes.future,
    ).timeout(const Duration(seconds: 1));

    expect(selection.kind, BackendRouteKind.direct);
    expect(selection.url, 'https://primary.example');
  });

  test('jalur langsung pulih meski gateway terakhir yang sehat', () async {
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example',
      fallbackUrl: 'https://fallback.example',
      anonKey: 'anon',
      lastReachableWasFallback: true,
      probe: (url, _) async => reachable,
    );

    expect(selection.kind, BackendRouteKind.direct);
    expect(selection.url, 'https://primary.example');
    expect(selection.usingFallback, isFalse);
  });

  test('jalur cadangan dipilih ketika alamat langsung diblokir', () async {
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example',
      fallbackUrl: 'https://fallback.example',
      anonKey: 'anon',
      probe: (url, _) async => url.contains('primary') ? blocked : reachable,
    );

    expect(selection.kind, BackendRouteKind.fallback);
    expect(selection.url, 'https://fallback.example');
    expect(selection.usingFallback, isTrue);
    expect(selection.label, 'Jalur cadangan otomatis');
  });

  test('gateway sehat tidak menunggu probe direct yang macet', () async {
    final directNeverFinishes = Completer<BackendProbeResult>();
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example',
      fallbackUrl: 'https://fallback.example',
      anonKey: 'anon',
      probe: (url, _) => url.contains('primary')
          ? directNeverFinishes.future
          : Future.value(reachable),
    ).timeout(const Duration(seconds: 1));

    expect(selection.kind, BackendRouteKind.fallback);
    expect(selection.url, 'https://fallback.example');
    expect(selection.fallback?.reachable, isTrue);
  });

  test('tetap memulai dalam mode offline ketika kedua jalur gagal', () async {
    final selection = await BackendRouteResolver.resolve(
      primaryUrl: 'https://primary.example',
      fallbackUrl: 'https://fallback.example',
      anonKey: 'anon',
      probe: (url, _) async => blocked,
    );

    expect(selection.kind, BackendRouteKind.unavailable);
    expect(selection.url, 'https://primary.example');
  });

  test(
    'mode offline memakai jalur pilihan agar pulih setelah Wi-Fi siap',
    () async {
      final selection = await BackendRouteResolver.resolve(
        primaryUrl: 'https://primary.example',
        fallbackUrl: 'https://fallback.example',
        anonKey: 'anon',
        lastReachableWasFallback: true,
        probe: (url, _) async => blocked,
      );

      expect(selection.kind, BackendRouteKind.unavailable);
      expect(selection.url, 'https://fallback.example');
    },
  );

  test(
    'konfigurasi server utama yang kosong dilaporkan dengan jelas',
    () async {
      var probeCalled = false;
      final selection = await BackendRouteResolver.resolve(
        primaryUrl: '',
        fallbackUrl: 'https://fallback.example',
        anonKey: 'anon',
        probe: (url, _) async {
          probeCalled = true;
          return reachable;
        },
      );

      expect(probeCalled, isFalse);
      expect(selection.kind, BackendRouteKind.unavailable);
      expect(selection.direct.error, contains('belum dikonfigurasi'));
    },
  );

  test('HTTP Date server diparse sebagai UTC untuk jam tepercaya', () {
    expect(
      parseHttpDate('Tue, 04 Aug 2026 08:00:05 GMT'),
      DateTime.utc(2026, 8, 4, 8, 0, 5),
    );
    expect(parseHttpDate('Tue, 32 Aug 2026 08:00:05 GMT'), isNull);
    expect(parseHttpDate('bukan tanggal'), isNull);
  });
}

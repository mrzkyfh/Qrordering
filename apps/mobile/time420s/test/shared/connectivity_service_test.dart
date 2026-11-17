import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/services/connectivity_service.dart';

void main() {
  group('connectivityProbeDelay', () {
    test('online tidak melakukan health probe setiap beberapa detik', () {
      expect(
        connectivityProbeDelay(isOnline: true),
        const Duration(minutes: 5),
      );
    });

    test('offline tetap diperiksa cepat untuk mendeteksi pemulihan', () {
      expect(
        connectivityProbeDelay(isOnline: false),
        const Duration(seconds: 15),
      );
      expect(
        connectivityProbeDelay(isOnline: false, offlineAttempt: 4),
        const Duration(minutes: 4),
      );
      expect(
        connectivityProbeDelay(isOnline: false, offlineAttempt: 20),
        const Duration(minutes: 4),
      );
    });
  });

  group('normalizeQueuedTimestampValue', () {
    const timestamp = '2026-07-31T06:10:00.000Z';

    test('mengoreksi waktu perangkat dengan offset server', () {
      final result = normalizeQueuedTimestampValue(
        timestamp,
        source: 'device',
        hasServerClock: true,
        serverClockOffset: const Duration(hours: 2, minutes: 15),
      );

      expect(result, '2026-07-31T08:25:00.000Z');
    });

    test('tidak mengoreksi timestamp yang sudah memakai waktu server', () {
      final result = normalizeQueuedTimestampValue(
        timestamp,
        source: 'server_offset',
        hasServerClock: true,
        serverClockOffset: const Duration(hours: 2),
      );

      expect(result, timestamp);
    });

    test('menjaga waktu perangkat ketika waktu server belum tersedia', () {
      final result = normalizeQueuedTimestampValue(
        timestamp,
        source: 'device',
        hasServerClock: false,
        serverClockOffset: const Duration(hours: 2),
      );

      expect(result, timestamp);
    });

    test('menjaga nilai timestamp yang tidak valid', () {
      const invalid = 'bukan-timestamp';
      final result = normalizeQueuedTimestampValue(
        invalid,
        source: 'device',
        hasServerClock: true,
        serverClockOffset: const Duration(hours: 2),
      );

      expect(result, invalid);
    });
  });
}

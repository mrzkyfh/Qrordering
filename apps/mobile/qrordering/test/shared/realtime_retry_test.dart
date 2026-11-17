import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/services/connectivity_service.dart';
import 'package:qrordering/shared/services/realtime_retry.dart';

/// Regresi: channel realtime Supabase tidak rejoin sendiri setelah
/// RealtimeSubscribeException — wrapper harus menyambung ulang otomatis dan
/// TIDAK meneruskan error ke listener (dulu listener mati permanen → notif
/// pesanan web & auto-cetak berhenti diam-diam; log error build 12–16).
void main() {
  tearDown(() {
    // Singleton — kembalikan ke default agar test lain tak terpengaruh.
    ConnectivityService.instance.online.value = true;
  });

  test(
    'error channel → subscribe ulang setelah backoff, error tak diteruskan',
    () {
      fakeAsync((async) {
        var attempt = 0;
        Stream<int> create() {
          attempt++;
          if (attempt == 1) {
            return Stream<int>.multi((c) {
              c.add(1);
              c.addError(Exception('channelError'));
            });
          }
          return Stream<int>.multi((c) => c.add(2));
        }

        final received = <int>[];
        final errors = <Object>[];
        final sub = retryingRealtimeStream(
          create,
          label: 'test',
        ).listen(received.add, onError: errors.add);

        async.flushMicrotasks();
        expect(received, [1], reason: 'data sebelum error tetap sampai');
        expect(attempt, 1);

        // Backoff pertama 3 detik → setelahnya harus subscribe ulang.
        async.elapse(const Duration(seconds: 4));
        expect(attempt, 2, reason: 'harus mencoba subscribe ulang');
        expect(received, [
          1,
          2,
        ], reason: 'data setelah reconnect mengalir lagi');
        expect(
          errors,
          isEmpty,
          reason: 'error ditelan wrapper, bukan diteruskan',
        );

        sub.cancel();
        async.flushTimers();
      });
    },
  );

  test('backoff naik eksponensial saat gagal beruntun', () {
    fakeAsync((async) {
      var attempt = 0;
      Stream<int> create() {
        attempt++;
        return Stream<int>.multi((c) => c.addError(Exception('down')));
      }

      final sub = retryingRealtimeStream(create).listen((_) {});
      async.flushMicrotasks();
      expect(attempt, 1);
      async.elapse(const Duration(seconds: 3)); // backoff 3s
      expect(attempt, 2);
      async.elapse(const Duration(seconds: 6)); // backoff 6s
      expect(attempt, 3);
      async.elapse(const Duration(seconds: 12)); // backoff 12s
      expect(attempt, 4);

      sub.cancel();
      async.flushTimers();
    });
  });

  test('stream selesai normal → subscribe ulang dan listener tetap hidup', () {
    fakeAsync((async) {
      var attempt = 0;
      Stream<int> create() {
        attempt++;
        if (attempt == 1) {
          return Stream<int>.multi((c) {
            c.add(1);
            c.close();
          });
        }
        return Stream<int>.multi((c) => c.add(2));
      }

      final received = <int>[];
      var listenerDone = false;
      final sub = retryingRealtimeStream(
        create,
        label: 'normal-close',
      ).listen(received.add, onDone: () => listenerDone = true);

      async.flushMicrotasks();
      expect(received, [1]);
      expect(attempt, 1);
      expect(
        listenerDone,
        isFalse,
        reason: 'selesainya upstream tidak boleh menutup listener aplikasi',
      );

      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(attempt, 2, reason: 'upstream normal-close harus disambung ulang');
      expect(received, [1, 2]);
      expect(listenerDone, isFalse);

      sub.cancel();
      async.flushTimers();
    });
  });

  test('konektivitas kembali online → retry dipercepat tanpa tunggu backoff', () {
    fakeAsync((async) {
      var attempt = 0;
      Stream<int> create() {
        attempt++;
        if (attempt == 1) {
          return Stream<int>.multi((c) => c.addError(Exception('down')));
        }
        return Stream<int>.multi((c) => c.add(9));
      }

      final received = <int>[];
      final sub = retryingRealtimeStream(create).listen(received.add);
      async.flushMicrotasks();
      expect(attempt, 1);

      // Belum lewat backoff (3s), tapi koneksi kembali online → langsung retry.
      ConnectivityService.instance.online.value = false;
      ConnectivityService.instance.online.value = true;
      async.flushMicrotasks();
      expect(attempt, 2, reason: 'online kembali harus memicu retry segera');
      expect(received, [9]);

      sub.cancel();
      async.flushTimers();
    });
  });

  test('cancel menghentikan retry (tidak ada subscribe hantu)', () {
    fakeAsync((async) {
      var attempt = 0;
      Stream<int> create() {
        attempt++;
        return Stream<int>.multi((c) => c.addError(Exception('down')));
      }

      final sub = retryingRealtimeStream(create).listen((_) {});
      async.flushMicrotasks();
      expect(attempt, 1);

      sub.cancel();
      async.elapse(const Duration(minutes: 5));
      expect(attempt, 1, reason: 'setelah cancel tidak boleh retry lagi');
    });
  });
}

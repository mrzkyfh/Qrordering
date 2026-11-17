import 'dart:async';
import 'package:flutter/foundation.dart';
import 'connectivity_service.dart';

/// Bungkus stream realtime Supabase agar MENYAMBUNG ULANG otomatis saat channel
/// putus.
///
/// Latar: `supabase.from(...).stream()` TIDAK rejoin sendiri setelah
/// `RealtimeSubscribeException` (channelError/timedOut) — begitu channel putus
/// (sinyal lemah, ganti jaringan, server restart), stream error lalu MATI
/// permanen. Semua fitur realtime (notif pesanan web, badge order, refresh
/// daftar order) ikut mati diam-diam sampai aplikasi di-restart. Log error
/// produksi menunjukkan persis pola ini di build 12–16.
///
/// Perilaku wrapper:
/// - Error ATAU stream yang selesai normal dari sumber TIDAK mematikan
///   listener — wrapper subscribe ulang dengan backoff eksponensial
///   (3s → 6s → ... maks 60s).
/// - Begitu konektivitas kembali online, retry dipercepat (tanpa menunggu
///   sisa backoff).
/// - Tiap kali tersambung ulang, Supabase mengirim snapshot penuh sebagai
///   data event pertama — konsumen menerima data segar secara otomatis.
Stream<T> retryingRealtimeStream<T>(
  Stream<T> Function() create, {
  String label = '',
  ValueChanged<bool>? onStatusChanged,
}) {
  late StreamController<T> controller;
  StreamSubscription<T>? sub;
  Timer? retryTimer;
  var backoff = const Duration(seconds: 3);
  var closed = false;
  var generation = 0;
  VoidCallback? onOnline;

  late void Function() subscribe;

  void scheduleRetry(int sourceGeneration, String reason) {
    if (closed || sourceGeneration != generation || retryTimer != null) return;

    // Invalidasi callback lain dari subscription yang sama. Ini mencegah
    // onError dan onDone menjadwalkan dua reconnect pada stream yang sama.
    generation++;
    onStatusChanged?.call(false);
    final delay = backoff;
    final previous = sub;
    sub = null;
    unawaited(previous?.cancel());

    debugPrint(
      'realtime[$label]: $reason — sambung ulang dalam ${delay.inSeconds}s',
    );
    retryTimer = Timer(delay, subscribe);
    backoff = Duration(seconds: (backoff.inSeconds * 2).clamp(3, 60));
  }

  subscribe = () {
    if (closed) return;
    retryTimer?.cancel();
    retryTimer = null;
    final sourceGeneration = ++generation;
    try {
      final nextSub = create().listen(
        (data) {
          if (closed || sourceGeneration != generation) return;
          backoff = const Duration(seconds: 3); // sehat → reset backoff
          onStatusChanged?.call(true);
          controller.add(data);
        },
        onError: (Object e, StackTrace st) {
          scheduleRetry(sourceGeneration, e.toString());
        },
        onDone: () {
          // Supabase dapat menutup channel tanpa mengirim error (mis. server
          // restart atau pergantian jaringan). Sebelumnya kondisi ini membuat
          // realtime mati permanen sampai aplikasi dibuka ulang.
          scheduleRetry(sourceGeneration, 'stream selesai');
        },
      );
      // Stream sinkron bisa selesai sebelum listen() mengembalikan
      // subscription. Jangan simpan subscription yang sudah invalid.
      if (!closed && sourceGeneration == generation && retryTimer == null) {
        sub = nextSub;
      } else {
        unawaited(nextSub.cancel());
      }
    } catch (e) {
      // create() bisa melempar sinkron (mis. client belum siap) → retry juga.
      scheduleRetry(sourceGeneration, 'gagal subscribe: $e');
    }
  };

  controller = StreamController<T>(
    onListen: () {
      // Fast-path: koneksi kembali online saat sedang menunggu backoff →
      // langsung coba sambung (jangan biarkan kasir menunggu sisa timer).
      onOnline = () {
        if (ConnectivityService.instance.online.value &&
            sub == null &&
            !closed) {
          subscribe();
        }
      };
      ConnectivityService.instance.online.addListener(onOnline!);
      subscribe();
    },
    onCancel: () {
      closed = true;
      generation++;
      onStatusChanged?.call(false);
      if (onOnline != null) {
        ConnectivityService.instance.online.removeListener(onOnline!);
      }
      retryTimer?.cancel();
      return sub?.cancel();
    },
  );

  return controller.stream;
}

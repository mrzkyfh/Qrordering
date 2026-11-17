import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../core/config/app_config.dart';
import 'backend_route_resolver.dart';

/// Mendeteksi apakah device benar-benar terhubung ke internet
/// (bukan hanya punya interface jaringan). Menggabungkan event
/// `connectivity_plus` dengan probe reachability nyata.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  /// true = online (internet terjangkau), false = offline.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _timer;
  Future<bool>? _inFlightCheck;
  int _offlineProbeAttempt = 0;
  Duration _serverClockOffset = Duration.zero;
  bool _hasServerClock = false;

  /// Apakah perangkat sudah pernah menerima waktu dari server pada sesi ini.
  /// Dipakai saat menyimpan transaksi offline agar replay dapat membedakan
  /// timestamp yang sudah terkoreksi dan timestamp mentah dari jam perangkat.
  bool get hasTrustedServerClock => _hasServerClock;
  final ValueNotifier<int?> latencyMs = ValueNotifier<int?>(null);
  final ValueNotifier<String> detail = ValueNotifier<String>('Belum diperiksa');
  final ValueNotifier<BackendRouteKind> reachableRoute =
      ValueNotifier<BackendRouteKind>(BackendRouteKind.unavailable);

  Future<void> init() async {
    await recheck();
    _sub = _connectivity.onConnectivityChanged.listen((_) => recheck());
  }

  /// Paksa pengecekan ulang (mis. setelah sebuah request gagal).
  Future<bool> recheck() {
    final running = _inFlightCheck;
    if (running != null) return running;
    _timer?.cancel();
    final check = _performCheck();
    _inFlightCheck = check;
    return check.whenComplete(() {
      if (identical(_inFlightCheck, check)) _inFlightCheck = null;
      _scheduleNextProbe();
    });
  }

  void _scheduleNextProbe() {
    _timer?.cancel();
    if (online.value) {
      _offlineProbeAttempt = 0;
    }
    final delay = connectivityProbeDelay(
      isOnline: online.value,
      offlineAttempt: _offlineProbeAttempt,
    );
    if (!online.value) _offlineProbeAttempt++;
    _timer = Timer(delay, () {
      recheck();
    });
  }

  Future<bool> _performCheck() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final hasInterface = results.any((r) => r != ConnectivityResult.none);
      if (hasInterface &&
          reachableRoute.value != BackendRouteKind.unavailable) {
        final activeResult = await BackendRouteResolver.probeActive(
          url: AppConfig.activeSupabaseUrl,
          anonKey: AppConfig.supabaseAnonKey,
        );
        if (activeResult.reachable) {
          latencyMs.value = activeResult.latencyMs;
          if (activeResult.serverTime != null) {
            _serverClockOffset = activeResult.serverTime!.difference(
              DateTime.now().toUtc(),
            );
            _hasServerClock = true;
          }
          reachableRoute.value = AppConfig.usingFallback
              ? BackendRouteKind.fallback
              : BackendRouteKind.direct;
          detail.value = AppConfig.usingFallback
              ? 'Terhubung melalui jalur kompatibel Wi-Fi'
              : 'Terhubung langsung ke server';
          if (!online.value) online.value = true;
          return true;
        }
      }
      final selection = hasInterface
          ? await BackendRouteResolver.resolve(
              primaryUrl: AppConfig.supabaseUrl,
              fallbackUrl: AppConfig.supabaseFallbackUrl,
              anonKey: AppConfig.supabaseAnonKey,
              lastReachableWasFallback:
                  reachableRoute.value == BackendRouteKind.fallback ||
                  AppConfig.usingFallback,
            )
          : BackendRouteSelection(
              url: AppConfig.activeSupabaseUrl,
              kind: BackendRouteKind.unavailable,
              direct: const BackendProbeResult(
                reachable: false,
                error: 'Perangkat tidak terhubung ke jaringan',
              ),
            );
      final reachable = selection.kind != BackendRouteKind.unavailable;
      final result = selection.usingFallback
          ? selection.fallback!
          : selection.direct;
      reachableRoute.value = selection.kind;
      latencyMs.value = reachable ? result.latencyMs : null;
      if (reachable && result.serverTime != null) {
        _serverClockOffset = result.serverTime!.difference(
          DateTime.now().toUtc(),
        );
        _hasServerClock = true;
      }
      detail.value = reachable
          ? selection.usingFallback
                ? 'Terhubung melalui jalur kompatibel Wi-Fi'
                : 'Terhubung langsung ke server'
          : selection.fallback?.error ??
                selection.direct.error ??
                'Server tidak dapat dijangkau';
      if (online.value != reachable) online.value = reachable;
      return reachable;
    } catch (error) {
      latencyMs.value = null;
      reachableRoute.value = BackendRouteKind.unavailable;
      detail.value = 'Pemeriksaan koneksi gagal: $error';
      if (online.value) online.value = false;
      return false;
    }
  }

  /// Waktu UTC yang dikoreksi dari header server terakhir. Timestamp offline
  /// yang dibuat dengan jam perangkat meleset akan dinormalisasi saat sinkron.
  DateTime trustedUtcNow() => _hasServerClock
      ? DateTime.now().toUtc().add(_serverClockOffset)
      : DateTime.now().toUtc();

  /// Koreksi timestamp yang dibuat dari jam perangkat sebelum waktu server
  /// tersedia. Timestamp yang sejak awal dibuat dengan [trustedUtcNow] tidak
  /// boleh dikoreksi lagi karena akan menggeser waktu dua kali.
  String normalizeQueuedTimestamp(String value, {required String source}) {
    return normalizeQueuedTimestampValue(
      value,
      source: source,
      hasServerClock: _hasServerClock,
      serverClockOffset: _serverClockOffset,
    );
  }

  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    latencyMs.dispose();
    detail.dispose();
    reachableRoute.dispose();
  }
}

/// Saat online, request aplikasi/realtime sudah menjadi sinyal konektivitas
/// utama sehingga health probe cukup lima menit sekali. Ketika offline, probe
/// dipercepat agar pemulihan tetap terdeteksi tanpa menunggu interaksi kasir.
@visibleForTesting
Duration connectivityProbeDelay({
  required bool isOnline,
  int offlineAttempt = 0,
}) {
  if (isOnline) return const Duration(minutes: 5);
  final exponent = offlineAttempt.clamp(0, 4);
  return Duration(seconds: 15 * (1 << exponent));
}

/// Pure variant used by [ConnectivityService] and timestamp regression tests.
/// Legacy queue entries are treated as device-clock timestamps by callers,
/// while entries marked `server_offset` remain unchanged.
@visibleForTesting
String normalizeQueuedTimestampValue(
  String value, {
  required String source,
  required bool hasServerClock,
  required Duration serverClockOffset,
}) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || source != 'device' || !hasServerClock) return value;
  return parsed.toUtc().add(serverClockOffset).toIso8601String();
}

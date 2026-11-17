import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wrapper untuk foreground service native (Android) yang menjaga PROSES aplikasi
/// tetap hidup saat UI diminimize — sehingga isolate utama (listener realtime
/// order + koneksi printer Bluetooth) terus berjalan untuk menerima & mencetak
/// pesanan online dari QR meja. No-op di luar Android.
class KeepAliveService {
  KeepAliveService._();
  static final KeepAliveService instance = KeepAliveService._();

  // Pakai channel yang sama dengan fitur Bluetooth (satu handler di MainActivity).
  static const _channel = MethodChannel('qrordering/bluetooth');
  static const _events = MethodChannel('qrordering/keep_alive_events');
  Future<void> Function()? _onBackgroundTick;
  bool _eventsAttached = false;

  /// Callback pemeriksaan order dari foreground service native. Dibutuhkan
  /// pada OEM yang menahan WebSocket Flutter ketika Activity berada di
  /// background walaupun proses dan foreground service masih hidup.
  set onBackgroundTick(Future<void> Function()? callback) {
    _onBackgroundTick = callback;
    if (_eventsAttached) return;
    _eventsAttached = true;
    _events.setMethodCallHandler((call) async {
      if (call.method != 'backgroundTick') return;
      try {
        await _onBackgroundTick?.call();
      } catch (e) {
        debugPrint('KeepAliveService background tick error: $e');
      }
    });
  }

  bool get _isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Mulai foreground service (idempoten di sisi native).
  Future<void> start() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startKeepAlive');
    } catch (e) {
      debugPrint('KeepAliveService.start error: $e');
    }
  }

  /// Hentikan foreground service (mis. saat logout).
  Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopKeepAlive');
    } catch (e) {
      debugPrint('KeepAliveService.stop error: $e');
    }
  }

  /// Apakah app sudah dikecualikan dari optimasi baterai.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Buka pengaturan optimasi baterai untuk pilihan manual pengguna.
  /// Tidak dipanggil otomatis agar sesuai kebijakan Google Play.
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint(
        'KeepAliveService.requestIgnoreBatteryOptimizations error: $e',
      );
    }
  }
}

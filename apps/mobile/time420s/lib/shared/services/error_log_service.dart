import 'dart:io' show Platform;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/config/app_config.dart';

/// Menahan banjir log dalam satu proses aplikasi.
///
/// Error identik hanya dikirim sekali per window. Error berbeda tetap dibatasi
/// agar satu perangkat bermasalah tidak memenuhi tabel observabilitas.
class ErrorLogPolicy {
  ErrorLogPolicy({
    this.maxUniquePerWindow = 5,
    this.window = const Duration(minutes: 10),
    DateTime? startedAt,
  }) : _windowStart = startedAt ?? DateTime.now();

  final int maxUniquePerWindow;
  final Duration window;
  DateTime _windowStart;
  int _accepted = 0;
  final Set<String> _seen = {};

  bool shouldReport(String message, String? stack, {DateTime? now}) {
    final current = now ?? DateTime.now();
    if (current.isBefore(_windowStart) ||
        current.difference(_windowStart) >= window) {
      _windowStart = current;
      _accepted = 0;
      _seen.clear();
    }

    final stackLines = stack?.split('\n');
    final firstStackLine = stackLines == null || stackLines.isEmpty
        ? ''
        : stackLines.first;
    final signature = '$message\n$firstStackLine';
    if (_seen.contains(signature) || _accepted >= maxUniquePerWindow) {
      return false;
    }

    _seen.add(signature);
    _accepted++;
    return true;
  }
}

String limitErrorLogField(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  const suffix = '\n… [dipotong]';
  if (maxLength <= suffix.length) return value.substring(0, maxLength);
  return '${value.substring(0, maxLength - suffix.length)}$suffix';
}

/// Kirim error tak tertangkap ke tabel `error_logs` (Supabase) untuk visibilitas
/// produksi. Best-effort + deduplicated + throttled — TIDAK PERNAH melempar
/// (dipanggil dari global error handler).
class ErrorLogService {
  ErrorLogService._();

  static final _policy = ErrorLogPolicy();
  static const _maxMessageLength = 1000;
  static const _maxStackLength = 4000;

  static Future<void> report(Object error, StackTrace? stack) async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) {
        return; // RLS butuh authenticated; lewati error pra-login
      }

      final message = limitErrorLogField(error.toString(), _maxMessageLength);
      final rawStack = stack?.toString();
      final safeStack = rawStack == null
          ? null
          : limitErrorLogField(rawStack, _maxStackLength);
      if (!_policy.shouldReport(message, safeStack)) return;

      await client.rpc('record_error_log', params: {
        'p_message': message,
        'p_stack': safeStack,
        'p_app_build': AppConfig.appBuild,
        'p_platform': Platform.operatingSystem,
      });
    } catch (_) {
      // best-effort — jangan pernah melempar dari handler error
    }
  }
}

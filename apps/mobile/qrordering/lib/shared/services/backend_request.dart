import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';

/// Returns true only for failures where the request may not have reached the
/// selected host (or its response may have been lost). This predicate controls
/// host failover and therefore deliberately excludes HTTP/PostgREST responses.
bool isBackendTransportFailure(Object error) {
  if (error is TimeoutException || error is http.ClientException) {
    return true;
  }
  if (error is PostgrestException ||
      error is FunctionException ||
      error is AuthException) {
    return false;
  }
  final message = error.toString().toLowerCase();
  return message.contains('socketexception') ||
      message.contains('failed host lookup') ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('connection refused') ||
      message.contains('failed to fetch') ||
      message.contains('network is unreachable');
}

/// Lebih luas dari [isBackendTransportFailure]: aman dipakai UI untuk beralih
/// ke outbox/cache ketika host berhasil dijangkau tetapi layanan backend sedang
/// tidak siap. Tidak dipakai untuk memilih host alternatif karena respons 5xx
/// membuktikan request sudah mencapai backend.
bool isBackendTemporarilyUnavailable(Object error) {
  if (isBackendTransportFailure(error)) return true;
  if (error is PostgrestException) {
    return const {
      'PGRST000', // database connection failed
      'PGRST001', // database connection lost
      'PGRST002', // database still starting/unavailable
    }.contains((error.code ?? '').toUpperCase());
  }
  return error is FunctionException && error.status >= 500;
}

/// Run an idempotent backend operation on the active route and retry once on
/// the alternate Supabase route when the failure is transport-only.
class BackendRequest {
  const BackendRequest._();

  static Future<T> withFallback<T>({
    required SupabaseClient client,
    required Future<T> Function(SupabaseClient client) operation,
    SupabaseClient? fallbackClient,
  }) async {
    try {
      return await operation(client);
    } catch (error) {
      if (!isBackendTransportFailure(error)) rethrow;

      final alternate = fallbackClient ?? _createAlternateClient(client);
      if (alternate == null) rethrow;
      try {
        return await operation(alternate);
      } finally {
        if (fallbackClient == null) {
          unawaited(alternate.dispose().catchError((_) {}));
        }
      }
    }
  }

  static SupabaseClient? _createAlternateClient(SupabaseClient client) {
    final active = _normalize(AppConfig.activeSupabaseUrl);
    final primary = _normalize(AppConfig.supabaseUrl);
    final fallback = _normalize(AppConfig.supabaseFallbackUrl);
    final alternate = active == fallback ? primary : fallback;
    if (alternate.isEmpty || alternate == active) return null;

    return SupabaseClient(
      alternate,
      AppConfig.supabaseAnonKey,
      accessToken: () async {
        try {
          return client.auth.currentSession?.accessToken;
        } catch (_) {
          return null;
        }
      },
    );
  }

  static String _normalize(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
}

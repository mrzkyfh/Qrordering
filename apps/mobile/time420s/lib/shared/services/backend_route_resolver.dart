import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

enum BackendRouteKind { direct, fallback, unavailable }

class BackendProbeResult {
  final bool reachable;
  final int? latencyMs;
  final String? error;
  final DateTime? serverTime;

  const BackendProbeResult({
    required this.reachable,
    this.latencyMs,
    this.error,
    this.serverTime,
  });
}

class BackendRouteSelection {
  final String url;
  final BackendRouteKind kind;
  final BackendProbeResult direct;
  final BackendProbeResult? fallback;

  const BackendRouteSelection({
    required this.url,
    required this.kind,
    required this.direct,
    this.fallback,
  });

  bool get usingFallback => kind == BackendRouteKind.fallback;

  String get label => switch (kind) {
    BackendRouteKind.direct => 'Jalur langsung',
    BackendRouteKind.fallback => 'Jalur cadangan otomatis',
    BackendRouteKind.unavailable => 'Belum terhubung',
  };
}

typedef BackendProbe =
    Future<BackendProbeResult> Function(String url, String anonKey);

class _ProbeCompletion {
  final bool direct;
  final BackendProbeResult? result;

  const _ProbeCompletion({required this.direct, required this.result});
}

/// Memilih jalur Supabase sebelum singleton Supabase dibuat.
///
/// Kedua jalur diperiksa bersamaan agar Wi-Fi yang memblokir satu domain tidak
/// menambah waktu tunggu dua kali. Jalur langsung selalu diprioritaskan bila
/// keduanya sehat.
class BackendRouteResolver {
  BackendRouteResolver._();

  static BackendRouteSelection? lastSelection;

  static Future<BackendRouteSelection> resolve({
    required String primaryUrl,
    required String fallbackUrl,
    required String anonKey,
    bool lastReachableWasFallback = false,
    BackendProbe? probe,
  }) async {
    final primary = _normalize(primaryUrl);
    final fallback = _normalize(fallbackUrl);
    final checker = probe ?? _probe;

    if (primary.isEmpty) {
      final result = BackendRouteSelection(
        url: primary,
        kind: BackendRouteKind.unavailable,
        direct: const BackendProbeResult(
          reachable: false,
          error: 'Alamat server utama belum dikonfigurasi',
        ),
      );
      lastSelection = result;
      return result;
    }

    // Mulai keduanya bersamaan. Bila direct sehat, aplikasi dapat lanjut segera
    // tanpa menunggu gateway yang mungkin diblokir atau timeout. Jika direct
    // gagal, probe fallback sudah berjalan sejak awal sehingga failover tidak
    // mendapat waktu tunggu tambahan.
    final directFuture = checker(primary, anonKey);
    final fallbackFuture = fallback.isEmpty || fallback == primary
        ? Future<BackendProbeResult?>.value(null)
        : checker(fallback, anonKey);
    // Return as soon as a healthy route is found. This prevents a blocked
    // gateway from holding up a healthy direct connection (and vice versa).
    // If the first result is a failure, wait for the other probe so offline
    // mode still has complete diagnostics and preserves direct priority when
    // both probes finish unsuccessfully.
    final first = await Future.any<_ProbeCompletion>([
      directFuture.then(
        (result) => _ProbeCompletion(direct: true, result: result),
      ),
      fallbackFuture.then(
        (result) => _ProbeCompletion(direct: false, result: result),
      ),
    ]);
    BackendProbeResult direct;
    BackendProbeResult? fallbackResult;
    if (first.result?.reachable == true) {
      if (first.direct) {
        direct = first.result!;
        final selection = BackendRouteSelection(
          url: primary,
          kind: BackendRouteKind.direct,
          direct: direct,
        );
        lastSelection = selection;
        return selection;
      }
      fallbackResult = first.result;
      // Gateway yang sehat tidak boleh menunggu domain utama yang diblokir
      // sampai timeout. Probe direct tetap dibiarkan berjalan untuk observasi,
      // tetapi startup segera memakai jalur yang sudah terbukti sehat.
      unawaited(
        directFuture.catchError(
          (_) => const BackendProbeResult(
            reachable: false,
            error: 'Probe jalur langsung selesai setelah fallback dipilih',
          ),
        ),
      );
      final selection = BackendRouteSelection(
        url: fallback,
        kind: BackendRouteKind.fallback,
        direct: const BackendProbeResult(
          reachable: false,
          error: 'Probe jalur langsung masih berjalan',
        ),
        fallback: fallbackResult,
      );
      lastSelection = selection;
      return selection;
    }

    if (first.direct) {
      direct = first.result!;
      fallbackResult = await fallbackFuture;
    } else {
      fallbackResult = first.result;
      direct = await directFuture;
    }

    if (direct.reachable) {
      final selection = BackendRouteSelection(
        url: primary,
        kind: BackendRouteKind.direct,
        direct: direct,
      );
      lastSelection = selection;
      return selection;
    }

    final selection = fallbackResult?.reachable == true
        ? BackendRouteSelection(
            url: fallback,
            kind: BackendRouteKind.fallback,
            direct: direct,
            fallback: fallbackResult,
          )
        : BackendRouteSelection(
            // Saat kedua probe gagal, pertahankan jalur terakhir yang pernah
            // sehat dan jangan menebak gateway.
            url: lastReachableWasFallback && fallback.isNotEmpty
                ? fallback
                : primary,
            kind: BackendRouteKind.unavailable,
            direct: direct,
            fallback: fallbackResult,
          );
    lastSelection = selection;
    return selection;
  }

  static Future<BackendProbeResult> probeActive({
    required String url,
    required String anonKey,
  }) => _probe(_normalize(url), anonKey);

  static Future<BackendProbeResult> _probe(String url, String anonKey) async {
    if (url.isEmpty) {
      return const BackendProbeResult(
        reachable: false,
        error: 'Alamat server kosong',
      );
    }
    final stopwatch = Stopwatch()..start();
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('$url/auth/v1/health'),
            headers: {
              if (anonKey.isNotEmpty) 'apikey': anonKey,
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();

      var validHealthPayload = false;
      if (response.statusCode == 200) {
        try {
          validHealthPayload =
              jsonDecode(response.body) is Map<String, dynamic>;
        } catch (_) {
          validHealthPayload = false;
        }
      }
      if (validHealthPayload) {
        return BackendProbeResult(
          reachable: true,
          latencyMs: stopwatch.elapsedMilliseconds,
          serverTime: parseHttpDate(response.headers['date']),
        );
      }
      return BackendProbeResult(
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: 'Server memberi respons ${response.statusCode}',
      );
    } on TimeoutException {
      return BackendProbeResult(
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: 'Koneksi melewati batas waktu',
      );
    } catch (_) {
      return BackendProbeResult(
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: 'Alamat server tidak dapat dijangkau',
      );
    } finally {
      client.close();
    }
  }

  static String _normalize(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
}

/// Parses the RFC 7231 date header used by HTTP servers without importing
/// `dart:io`, so this stays compatible with Flutter Web builds too.
DateTime? parseHttpDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parts = value.trim().split(RegExp(r'[\s,:]+'));
  // Example: Tue, 04 Aug 2026 08:00:00 GMT
  if (parts.length < 7) return null;
  const months = <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final day = int.tryParse(parts[1]);
  final month = months[parts[2].toLowerCase()];
  final year = int.tryParse(parts[3]);
  final hour = int.tryParse(parts[4]);
  final minute = int.tryParse(parts[5]);
  final second = int.tryParse(parts[6]);
  if ([day, month, year, hour, minute, second].contains(null)) return null;
  try {
    final parsed = DateTime.utc(year!, month!, day!, hour!, minute!, second!);
    // DateTime normalizes invalid dates, therefore verify every component.
    if (parsed.year != year ||
        parsed.month != month ||
        parsed.day != day ||
        parsed.hour != hour ||
        parsed.minute != minute ||
        parsed.second != second) {
      return null;
    }
    return parsed;
  } catch (_) {
    return null;
  }
}

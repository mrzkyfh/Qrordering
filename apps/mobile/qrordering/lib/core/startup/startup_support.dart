import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StartupTimeoutException implements Exception {
  const StartupTimeoutException(this.category, this.timeout);

  final String category;
  final Duration timeout;

  @override
  String toString() => '$category after ${timeout.inSeconds}s';
}

Future<T> runStartupOperation<T>({
  required String category,
  required Duration timeout,
  required Future<T> Function() operation,
}) {
  return operation().timeout(
    timeout,
    onTimeout: () => throw StartupTimeoutException(category, timeout),
  );
}

/// Metadata startup yang aman untuk disimpan: tidak menerima payload, token,
/// credential, atau encryption key. Riwayat dibatasi agar tidak tumbuh bebas.
class StartupDiagnostics {
  StartupDiagnostics._();

  static const _storageKey = 'startup_failure_diagnostics_v1';
  static const _maxRecords = 5;
  static const _storageTimeout = Duration(seconds: 3);

  static String currentPhase = 'not_started';
  static Stopwatch _elapsed = Stopwatch();

  static void begin() {
    currentPhase = 'bootstrap_start';
    _elapsed = Stopwatch()..start();
  }

  static void phase(String value) {
    currentPhase = value;
    debugPrint(
      'STARTUP phase=$value elapsed_ms=${_elapsed.elapsedMilliseconds}',
    );
  }

  static Future<void> recordFailure(
    Object error,
    StackTrace stack, {
    required int appBuild,
    String? phaseOverride,
  }) async {
    final phaseName = phaseOverride ?? currentPhase;
    final category = error is StartupTimeoutException
        ? error.category
        : error.runtimeType.toString();
    final durationMs = _elapsed.elapsedMilliseconds;
    debugPrint(
      'STARTUP FAILURE phase=$phaseName category=$category '
      'duration_ms=$durationMs build=$appBuild\n$stack',
    );

    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        _storageTimeout,
      );
      final records = <Object?>[];
      final existing = preferences.getString(_storageKey);
      if (existing != null) {
        try {
          final decoded = jsonDecode(existing);
          if (decoded is List) records.addAll(decoded);
        } catch (_) {
          // Diagnostic yang rusak boleh diganti; tidak berisi data transaksi.
        }
      }
      records.add({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'phase': phaseName,
        'category': category,
        'app_build': appBuild,
        'duration_ms': durationMs,
      });
      if (records.length > _maxRecords) {
        records.removeRange(0, records.length - _maxRecords);
      }
      await preferences
          .setString(_storageKey, jsonEncode(records))
          .timeout(_storageTimeout);
    } catch (diagnosticError) {
      debugPrint('STARTUP diagnostic persistence skipped: $diagnosticError');
    }
  }
}

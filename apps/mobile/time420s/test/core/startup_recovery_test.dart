import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/core/widgets/startup_gate.dart';
import 'package:time420s/core/startup/startup_support.dart';
import 'package:time420s/main.dart' show isStoredSupabaseSessionValid;

void main() {
  test('sesi Supabase korup dikenali sebelum restore startup', () {
    expect(isStoredSupabaseSessionValid('{terpotong'), isFalse);
    expect(isStoredSupabaseSessionValid('{}'), isFalse);
    expect(
      isStoredSupabaseSessionValid('{"access_token":"token-valid"}'),
      isTrue,
    );
  });

  testWidgets('startup gagal tetap menampilkan UI dan dapat dicoba ulang', (
    tester,
  ) async {
    var attempts = 0;
    final secondAttempt = Completer<void>();

    await tester.pumpWidget(
      StartupGate(
        initialize: () {
          attempts++;
          if (attempts == 1) return Future<void>.error(StateError('rusak'));
          return secondAttempt.future;
        },
        readyBuilder: (_) => const MaterialApp(home: Text('POS siap')),
      ),
    );
    await tester.pump();

    expect(find.text('Tidak dapat membuka aplikasi'), findsOneWidget);
    expect(find.text('Coba Lagi'), findsOneWidget);
    expect(
      find.textContaining('Data transaksi lokal tidak dihapus'),
      findsOneWidget,
    );

    await tester.tap(find.text('Coba Lagi'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Menyiapkan aplikasi kasir…'), findsOneWidget);

    secondAttempt.complete();
    await tester.pumpAndSettle();
    expect(find.text('POS siap'), findsOneWidget);
  });

  testWidgets('startup yang tidak pernah selesai mencapai recovery UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupGate(
        deadline: const Duration(milliseconds: 100),
        initialize: () => Completer<void>().future,
        readyBuilder: (_) => const MaterialApp(home: Text('POS siap')),
      ),
    );

    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();

    expect(find.text('Tidak dapat membuka aplikasi'), findsOneWidget);
    expect(find.text('Coba Lagi'), findsOneWidget);
  });

  for (final category in const [
    'HIVE_INIT_TIMEOUT',
    'SECURE_STORAGE_TIMEOUT',
    'SUPABASE_INIT_TIMEOUT',
  ]) {
    testWidgets('$category ditampilkan sebagai recovery UI, bukan raw error', (
      tester,
    ) async {
      await tester.pumpWidget(
        StartupGate(
          deadline: const Duration(seconds: 1),
          initialize: () => runStartupOperation<void>(
            category: category,
            timeout: const Duration(milliseconds: 50),
            operation: () => Completer<void>().future,
          ),
          readyBuilder: (_) => const MaterialApp(home: Text('POS siap')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 51));
      await tester.pump();

      expect(find.text('Tidak dapat membuka aplikasi'), findsOneWidget);
      expect(find.textContaining(category), findsNothing);
    });
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:time420s/app.dart';
import 'package:time420s/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:time420s/shared/services/supabase_service.dart';

class _MockSupabaseService extends Mock implements SupabaseService {}

void main() {
  testWidgets(
    'auth restore timeout menampilkan recovery dan dapat dicoba lagi',
    (tester) async {
      final service = _MockSupabaseService();
      final blockedRead = Completer<String?>();
      when(() => service.currentSession).thenReturn(null);
      when(
        () => service.storedDeviceUserId,
      ).thenAnswer((_) => blockedRead.future);
      when(() => service.hasDeviceCreds).thenAnswer((_) async => false);
      final bloc = AuthBloc(supabaseService: service)
        ..add(AuthCheckRequested());
      addTearDown(bloc.close);

      await tester.pumpWidget(
        BlocProvider.value(
          value: bloc,
          child: const MaterialApp(
            home: AuthWatchdog(
              deadline: Duration(milliseconds: 100),
              child: Text('Splash'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 101));
      await tester.pump();

      expect(find.text('Tidak dapat membuka aplikasi'), findsOneWidget);
      expect(find.text('Coba Lagi'), findsOneWidget);

      blockedRead.complete(null);
      await tester.tap(find.text('Coba Lagi'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Tidak dapat membuka aplikasi'), findsNothing);
      // Selesaikan timeout best-effort penyimpanan diagnostic pada test binding.
      await tester.pump(const Duration(seconds: 4));
    },
  );

  test('navigation occurs before a cleanup future completes', () async {
    var navigated = false;
    final cleanup = Completer<void>();

    navigateBeforeCleanup(
      navigate: () => navigated = true,
      cleanup: () => cleanup.future,
    );

    expect(navigated, isTrue);
    expect(cleanup.isCompleted, isFalse);
    cleanup.complete();
  });
}

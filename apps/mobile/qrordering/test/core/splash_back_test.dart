import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qrordering/features/auth/presentation/pages/splash_page.dart';

void main() {
  testWidgets('system back pada splash tidak melempar exception', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (context, state) => const SplashPage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SplashPage), findsOneWidget);
  });
}

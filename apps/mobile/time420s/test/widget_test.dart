import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Smoke test: widget dasar Flutter berfungsi
void main() {
  testWidgets('Widget dasar dapat dirender tanpa error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('time420s')),
        ),
      ),
    );
    expect(find.text('time420s'), findsOneWidget);
  });
}

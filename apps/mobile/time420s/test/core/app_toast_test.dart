import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/core/widgets/app_toast.dart';

void main() {
  testWidgets('toast aman diganti ketika animasi dismiss masih berjalan', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    AppToast.info(context, 'Toast pertama');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));

    // Toast pertama sedang reverse. Menggantinya tidak boleh memanggil
    // OverlayEntry.remove dua kali setelah animasi pertama selesai.
    AppToast.error(context, 'Toast kedua');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
}

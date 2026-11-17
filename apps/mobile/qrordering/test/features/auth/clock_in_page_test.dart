import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/auth/presentation/pages/clock_in_page.dart';

void main() {
  group('clockInErrorMessage', () {
    test('hanya kegagalan verifikasi yang disebut PIN salah', () {
      expect(
        clockInErrorMessage('Exception: PIN salah'),
        'PIN salah, coba lagi',
      );
      expect(clockInErrorMessage('PIN tidak valid'), 'PIN salah, coba lagi');
    });

    test('gangguan proses setelah PIN tidak ditampilkan sebagai PIN salah', () {
      expect(
        clockInErrorMessage('Profil belum siap'),
        'PIN sudah diterima, tetapi proses masuk belum selesai. Coba lagi.',
      );
      expect(
        clockInErrorMessage('SocketException: connection failed'),
        'Koneksi bermasalah. Periksa internet Anda lalu coba lagi.',
      );
    });

    test('pesan PIN terkunci dipertahankan', () {
      expect(
        clockInErrorMessage('PIN terkunci, coba lagi dalam 5 menit'),
        'PIN terkunci, coba lagi dalam 5 menit',
      );
    });
  });

  testWidgets('papan PIN tampil tanpa Expanded bertumpuk pada layar kasir', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pressed = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: buildClockInNumpadForTest(onKey: pressed.add),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('0'));
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    expect(pressed, ['0', '<']);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time420s/shared/services/printer_service.dart';

/// Regression untuk fix cetak kasir+dapur di 1 printer:
///  - antrean cetak (mutex) menjalankan job SATU PER SATU, tidak interleave;
///  - jeda antar-cetak tersimpan, ter-clamp, dan konsisten dibaca.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Antrean cetak (_synchronized) — serialisasi', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('job berjalan berurutan FIFO, tidak saling menyela', () async {
      final ps = PrinterService();
      await ps.setPrintGapMs(0); // buang jeda agar uji murni soal urutan
      final log = <String>[];

      Future<void> job(String tag) => ps.runSerializedForTest(() async {
        log.add('start-$tag');
        // Beri kesempatan job lain menyela BILA mutex bocor.
        await Future.delayed(const Duration(milliseconds: 20));
        log.add('end-$tag');
      });

      // Tembak tiga job "berbarengan" (tanpa await antar-launch).
      final f1 = job('A');
      final f2 = job('B');
      final f3 = job('C');
      await Future.wait([f1, f2, f3]);

      // Serial → tiap start langsung diikuti end-nya sendiri, urut FIFO.
      expect(log, [
        'start-A',
        'end-A',
        'start-B',
        'end-B',
        'start-C',
        'end-C',
      ]);
    });

    test('error satu job tidak mematikan antrean untuk job berikutnya', () async {
      final ps = PrinterService();
      await ps.setPrintGapMs(0);
      final done = <String>[];

      final bad = ps.runSerializedForTest(() async {
        throw StateError('printer meledak');
      });
      final good = ps.runSerializedForTest(() async {
        done.add('lanjut');
      });

      await expectLater(bad, throwsStateError);
      await good;
      expect(done, ['lanjut']); // antrean tetap hidup
    });
  });

  group('Jeda antar-cetak (printGapMs)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('set lalu baca mengembalikan nilai yang sama', () async {
      final ps = PrinterService();
      await ps.setPrintGapMs(2000);
      expect(await ps.printGapMs(), 2000);
    });

    test('nilai negatif & di atas batas ter-clamp ke 0..10000', () async {
      final ps = PrinterService();
      await ps.setPrintGapMs(-500);
      expect(await ps.printGapMs(), 0);
      await ps.setPrintGapMs(999999);
      expect(await ps.printGapMs(), 10000);
    });

    test('jeda benar-benar menahan job berikutnya di antrean', () async {
      final ps = PrinterService();
      await ps.setPrintGapMs(120);
      // Job pertama selesai instan; job kedua tak boleh mulai sebelum jeda.
      final sw = Stopwatch()..start();
      await ps.runSerializedForTest(() async {});
      final afterFirst = sw.elapsedMilliseconds;
      await ps.runSerializedForTest(() async {});
      sw.stop();
      // Job kedua menunggu jeda ~120ms setelah job pertama.
      expect(
        sw.elapsedMilliseconds - afterFirst,
        greaterThanOrEqualTo(100),
        reason: 'job kedua harus tertahan jeda ~120ms',
      );
      await ps.setPrintGapMs(0); // bersihkan untuk test lain
    });
  });
}

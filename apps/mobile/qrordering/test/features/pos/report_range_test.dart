import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/pos/presentation/widgets/report_common.dart';

void main() {
  // Regresi timezone: fromIso/toIso dulu memakai tanggal LOKAL + suffix 'Z'
  // ('${from}T00:00:00.000Z'), sehingga filter timestamptz meleset sebesar
  // offset zona (7 jam di WIB) — transaksi sebelum jam 07:00 masuk ke laporan
  // hari sebelumnya. Sekarang batas hari lokal dikonversi ke instan UTC asli.
  group('ReportRange fromIso/toIso', () {
    const range = ReportRange('2026-07-10', '2026-07-11', 'label');

    test('fromIso = tengah malam LOKAL 10 Jul sebagai instan UTC', () {
      final parsed = DateTime.parse(range.fromIso);
      expect(parsed.isUtc, isTrue);
      // Kembali ke lokal harus tepat 2026-07-10 00:00:00 lokal.
      final local = parsed.toLocal();
      expect(local.year, 2026);
      expect(local.month, 7);
      expect(local.day, 10);
      expect(local.hour, 0);
      expect(local.minute, 0);
    });

    test('toIso = akhir hari LOKAL 11 Jul (23:59:59.999) sebagai instan UTC', () {
      final parsed = DateTime.parse(range.toIso);
      expect(parsed.isUtc, isTrue);
      final local = parsed.toLocal();
      expect(local.year, 2026);
      expect(local.month, 7);
      expect(local.day, 11);
      expect(local.hour, 23);
      expect(local.minute, 59);
      expect(local.second, 59);
      expect(local.millisecond, 999);
    });

    test('rentang menutup satu hari penuh tanpa celah/tumpang tindih', () {
      const today = ReportRange('2026-07-10', '2026-07-10', 'hari ini');
      const tomorrow = ReportRange('2026-07-11', '2026-07-11', 'besok');
      final endToday = DateTime.parse(today.toIso);
      final startTomorrow = DateTime.parse(tomorrow.fromIso);
      // Akhir hari ini persis 1 ms sebelum awal besok.
      expect(startTomorrow.difference(endToday).inMilliseconds, 1);
    });
  });
}

import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/services/printer_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('emoji di catatan dibuang sebelum teks dikodekan printer', () {
    final emoji = String.fromCharCode(0x1f64f);
    const note = '> BOLEH DEPE TELUR PUYUH GANTI BAKSO JOH';
    final printable = stripEmojiForPrinter('$note$emoji$emoji');

    expect(printable, note);
    expect(() => latin1.encode(printable), returnsNormally);
  });

  test('teks biasa dan karakter Indonesia tetap dipertahankan', () {
    expect(
      stripEmojiForPrinter('Catatan: cabai, telur, dan saus'),
      'Catatan: cabai, telur, dan saus',
    );
  });

  test('semua field dinamis aman untuk encoder meski berisi Unicode', () {
    final input = 'Dewiiii 😊 “Pedas” — 漢字';
    final printable = sanitizePrinterText(input);

    expect(printable, 'Dewiiii  "Pedas" - ');
    expect(() => latin1.encode(printable), returnsNormally);
  });

  test(
    'wrapper Generator menyaring karakter sebelum encoding ESC/POS',
    () async {
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm58, profile);

      expect(() => generator.safeText('Custom item 🔥'), returnsNormally);
    },
  );

  test('judul section catatan memenuhi lebar kertas dan tetap di tengah', () {
    final title = printerSectionTitle('Catatan Order', 32);

    expect(title.length, 32);
    expect(title, contains('CATATAN ORDER'));
    expect(title.startsWith('-'), true);
    expect(title.endsWith('-'), true);
  });
}

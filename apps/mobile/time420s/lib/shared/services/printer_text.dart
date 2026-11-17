import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

bool _isEmojiCodePoint(int rune) =>
    (rune >= 0x1f000 && rune <= 0x1faff) ||
    (rune >= 0x2600 && rune <= 0x27bf) ||
    (rune >= 0xe0020 && rune <= 0xe007f) ||
    rune == 0x200d ||
    rune == 0x20e3 ||
    rune == 0xfe0e ||
    rune == 0xfe0f;

/// Ubah teks bebas dari database/form menjadi teks yang aman untuk encoder
/// ESC/POS. Data asli tidak diubah; sanitasi hanya dilakukan pada payload cetak.
///
/// `esc_pos_utils_plus` melempar `Invalid argument (string): Contains invalid
/// characters` bila menerima rune di luar code page 8-bit. Emoji adalah kasus
/// paling umum, tetapi smart punctuation dan karakter kontrol hasil copy-paste
/// dapat menimbulkan kegagalan yang sama. Karakter umum dinormalisasi, lalu rune
/// yang tidak dapat direpresentasikan sebagai byte dibuang agar satu karakter
/// tidak membatalkan seluruh struk.
String sanitizePrinterText(String text) {
  final normalized = text
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201c', '"')
      .replaceAll('\u201d', '"')
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('\u2026', '...')
      .replaceAll('\u00a0', ' ');
  return String.fromCharCodes(
    normalized.runes.where(
      (rune) =>
          !_isEmojiCodePoint(rune) &&
          (rune == 0x0a ||
              rune == 0x0d ||
              rune == 0x09 ||
              (rune >= 0x20 && rune <= 0xff)),
    ),
  );
}

/// Nama lama dipertahankan agar callsite lama tetap kompatibel.
String stripEmojiForPrinter(String text) => sanitizePrinterText(text);

extension SafePrinterGenerator on Generator {
  List<int> safeText(String text, {PosStyles styles = const PosStyles()}) =>
      this.text(sanitizePrinterText(text), styles: styles);
}

/// Bungkus teks pada batas kata untuk printer thermal. Kata yang memang lebih
/// panjang dari [width] tetap dipotong aman agar tidak melewati area cetak.
List<String> wrapPrinterText(String value, int width) {
  assert(width > 0);
  final clean = sanitizePrinterText(
    value,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return const [''];
  final lines = <String>[];
  var current = '';
  for (final word in clean.split(' ')) {
    if (word.length > width) {
      if (current.isNotEmpty) {
        lines.add(current);
        current = '';
      }
      var remaining = word;
      while (remaining.length > width) {
        lines.add(remaining.substring(0, width));
        remaining = remaining.substring(width);
      }
      current = remaining;
      continue;
    }
    final candidate = current.isEmpty ? word : '$current $word';
    if (candidate.length <= width) {
      current = candidate;
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

/// Judul section yang memenuhi satu baris thermal, misalnya:
/// `-------- CATATAN ORDER --------`.
String printerSectionTitle(String label, int width) {
  final clean = sanitizePrinterText(
    label,
  ).replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();
  if (clean.length + 2 >= width) return clean.substring(0, width);
  final dashCount = width - clean.length - 2;
  final left = dashCount ~/ 2;
  final right = dashCount - left;
  return '${'-' * left} $clean ${'-' * right}';
}

/// Final feed/cut tunggal untuk seluruh dokumen thermal.
///
/// `Generator.cut()` menyisipkan lima LF. Itu bertumpuk dengan feed milik
/// formatter dan menghasilkan kertas kosong panjang, khususnya pada printer
/// tanpa cutter. Sisakan tiga baris untuk manual tear lalu pertahankan command
/// cut-nya.
List<int> compactFinalCut(Generator generator) {
  final generated = generator.cut();
  var commandStart = 0;
  while (commandStart < generated.length && generated[commandStart] == 0x0a) {
    commandStart++;
  }
  return <int>[...generator.feed(3), ...generated.sublist(commandStart)];
}

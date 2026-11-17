import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Formatter input angka dengan pemisah ribuan gaya Indonesia (titik): 10.000.
/// Hanya menerima digit; titik ditambahkan otomatis saat mengetik.
class ThousandsInputFormatter extends TextInputFormatter {
  static final NumberFormat _fmt = NumberFormat.decimalPattern('id_ID');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    // Ambil hanya digit.
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(text: '');
    }
    final number = int.tryParse(digits);
    if (number == null) return oldValue;
    final formatted = _fmt.format(number);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Ambil nilai numerik dari teks ber-pemisah ribuan ('10.000' → 10000).
double parseThousands(String text) =>
    double.tryParse(text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

/// Format angka jadi teks ber-pemisah ribuan untuk nilai awal field (10000 → '10.000').
String formatThousands(num value) =>
    NumberFormat.decimalPattern('id_ID').format(value.round());

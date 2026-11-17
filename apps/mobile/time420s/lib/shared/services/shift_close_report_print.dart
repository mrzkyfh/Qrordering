import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:intl/intl.dart';
import '../models/shift_close_report.dart';
import 'printer_service.dart';
import 'printer_text.dart';

class ShiftCloseReportBuilder {
  final ShiftCloseReport report;
  final PaperSize paperSize;
  final String driver;
  final bool includeProducts;

  const ShiftCloseReportBuilder({
    required this.report,
    this.paperSize = PaperSize.mm58,
    this.driver = 'generic1',
    this.includeProducts = true,
  });

  static const _paymentLabels = <String, String>{
    'cash': 'Tunai',
    'qris': 'QRIS',
    'debit': 'Debit',
    'credit': 'Kartu Kredit',
    'ewallet': 'E-Wallet',
    'transfer': 'Transfer',
  };

  static const _expenseLabels = <String, String>{
    'bahan_baku': 'Bahan Baku',
    'operasional': 'Operasional',
    'gaji': 'Gaji',
    'peralatan': 'Peralatan',
    'marketing': 'Pemasaran',
    'lain_lain': 'Lain-lain',
  };

  String _money(double value) =>
      NumberFormat('#,##0', 'id_ID').format(value.round());

  String _date(DateTime value) =>
      DateFormat('dd MMM yyyy, HH:mm', 'id_ID').format(value.toLocal());

  // Gunakan lebar Font A yang didukung konsisten oleh printer 58/80 mm.
  // Sebagian printer mengabaikan perintah Font B sehingga teks 42 karakter
  // pada kertas 58 mm terpotong atau pindah baris di posisi yang tidak tepat.
  int get _detailChars => paperSize == PaperSize.mm80 ? 48 : 32;

  String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

  List<String> _wrap(String value, int width) {
    final clean = _clean(value);
    if (clean.isEmpty) return [''];
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

  List<int> _detailText(
    Generator generator,
    String text, {
    bool bold = false,
    PosAlign align = PosAlign.left,
  }) => generator.safeText(
    text,
    styles: PosStyles(fontType: PosFontType.fontA, bold: bold, align: align),
  );

  List<int> _divider(Generator generator) =>
      _detailText(generator, '-' * _detailChars);

  List<int> _section(Generator generator, String title) =>
      _detailText(generator, title.toUpperCase(), bold: true);

  List<int> _keyValue(
    Generator generator,
    String label,
    String value, {
    bool bold = false,
    bool alignValueRight = true,
  }) {
    final safeLabel = _clean(label);
    final safeValue = _clean(value);
    final bytes = <int>[];

    // Jika label dan nilai tidak muat, pindahkan nilai utuh ke baris baru.
    // Dengan begitu printer tidak memecah nominal atau tanggal sendiri.
    final valueWidth = _detailChars - safeLabel.length - 1;
    if (valueWidth > 0 && safeValue.length <= valueWidth) {
      bytes.addAll(
        _detailText(
          generator,
          '$safeLabel${alignValueRight ? safeValue.padLeft(valueWidth) : ' $safeValue'}',
          bold: bold,
        ),
      );
      return bytes;
    }

    bytes.addAll(_detailText(generator, safeLabel, bold: bold));
    final values = _wrap(safeValue, _detailChars);
    for (var i = 0; i < values.length; i++) {
      bytes.addAll(
        _detailText(
          generator,
          alignValueRight ? values[i].padLeft(_detailChars) : values[i],
          bold: bold,
        ),
      );
    }
    return bytes;
  }

  List<int> _nameAmount(
    Generator generator,
    String name,
    double amount, {
    bool bold = false,
  }) {
    final amountText = _money(amount);
    final amountWidth = amountText.length + 2;
    final nameWidth = _detailChars - amountWidth;
    final names = _wrap(name, nameWidth);
    final bytes = <int>[];
    for (var i = 0; i < names.length; i++) {
      bytes.addAll(
        _detailText(
          generator,
          '${names[i].padRight(nameWidth)}'
          '${i == 0 ? amountText.padLeft(amountWidth) : ' ' * amountWidth}',
          bold: bold,
        ),
      );
    }
    return bytes;
  }

  List<int> _productLine(Generator generator, ShiftProductSummary product) {
    const qtyWidth = 5;
    final nameWidth = _detailChars - qtyWidth;
    final names = _wrap(product.name.toUpperCase(), nameWidth);
    final bytes = <int>[];
    for (var i = 0; i < names.length; i++) {
      bytes.addAll(
        _detailText(
          generator,
          '${names[i].padRight(nameWidth)}'
          '${i == 0 ? '${product.quantity}'.padLeft(qtyWidth) : ' ' * qtyWidth}',
        ),
      );
    }
    return bytes;
  }

  Future<List<int>> build() async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.safeText(
        report.outlet.name.toUpperCase(),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
    );
    if (report.outlet.address.isNotEmpty) {
      bytes.addAll(
        generator.safeText(
          report.outlet.address,
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    if (report.outlet.city.isNotEmpty &&
        !report.outlet.address.toLowerCase().contains(
          report.outlet.city.toLowerCase(),
        )) {
      bytes.addAll(
        generator.safeText(
          report.outlet.city,
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    if (report.outlet.phone.isNotEmpty) {
      bytes.addAll(
        generator.safeText(
          'Telp: ${report.outlet.phone}',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    bytes.addAll(generator.feed(1));
    bytes.addAll(_divider(generator));
    bytes.addAll(
      generator.safeText(
        'LAPORAN TUTUP KASIR',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
    );
    bytes.addAll(
      generator.safeText(
        'TRANSAKSI PENJUALAN',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
    );
    if (report.isProvisional) {
      bytes.addAll(
        generator.safeText(
          'SEMENTARA - MENUNGGU SINKRONISASI',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      );
    }
    bytes.addAll(_divider(generator));

    bytes.addAll(_section(generator, 'Informasi Shift'));
    bytes.addAll(
      _keyValue(generator, 'Kasir', report.cashierName, alignValueRight: false),
    );
    bytes.addAll(
      _keyValue(
        generator,
        'Waktu Buka',
        _date(report.openedAt),
        alignValueRight: false,
      ),
    );
    bytes.addAll(
      _keyValue(
        generator,
        'Waktu Tutup',
        _date(report.closedAt),
        alignValueRight: false,
      ),
    );
    bytes.addAll(_divider(generator));

    bytes.addAll(_section(generator, 'Penerimaan'));
    bytes.addAll(
      _keyValue(generator, 'Modal Awal', _money(report.openingCash)),
    );
    for (final payment in report.paymentMethods) {
      if (payment.amount == 0) continue;
      bytes.addAll(
        _keyValue(
          generator,
          _paymentLabels[payment.method] ?? payment.method.toUpperCase(),
          _money(payment.amount),
        ),
      );
    }
    if (report.cashIn != 0) {
      bytes.addAll(_keyValue(generator, 'Kas Masuk', _money(report.cashIn)));
    }
    if (report.cashOut != 0) {
      bytes.addAll(
        _keyValue(generator, 'Pengeluaran Kas', '-${_money(report.cashOut)}'),
      );
    }
    bytes.addAll(
      _keyValue(
        generator,
        'Total Penerimaan',
        _money(report.totalReceipts),
        bold: true,
      ),
    );
    bytes.addAll(_divider(generator));
    bytes.addAll(_section(generator, 'Rekonsiliasi Kas'));
    bytes.addAll(
      _keyValue(generator, 'Saldo Seharusnya', _money(report.expectedCash)),
    );
    bytes.addAll(
      _keyValue(generator, 'Kas Fisik', _money(report.closingCash), bold: true),
    );
    bytes.addAll(
      _keyValue(
        generator,
        'Selisih Kas',
        _money(report.cashDifference),
        bold: true,
      ),
    );
    bytes.addAll(_divider(generator));

    bytes.addAll(_section(generator, 'Ringkasan Transaksi'));
    if (report.taxTotal != 0) {
      bytes.addAll(_keyValue(generator, 'Pajak', _money(report.taxTotal)));
    }
    if (report.serviceChargeTotal != 0) {
      bytes.addAll(
        _keyValue(
          generator,
          'Biaya Layanan',
          _money(report.serviceChargeTotal),
        ),
      );
    }
    if (report.discountTotal != 0) {
      bytes.addAll(
        _keyValue(generator, 'Diskon', _money(report.discountTotal)),
      );
    }
    if (report.refundTotal != 0) {
      bytes.addAll(_keyValue(generator, 'Refund', _money(report.refundTotal)));
    }
    if (report.voidItemQuantity > 0) {
      bytes.addAll(
        _keyValue(
          generator,
          'Void Item',
          '${report.voidItemQuantity} / ${_money(report.voidItemAmount)}',
        ),
      );
    }
    bytes.addAll(
      _keyValue(
        generator,
        'Transaksi Selesai',
        '${report.completedTransactions}',
      ),
    );
    bytes.addAll(
      _keyValue(generator, 'Belum Terbayar', '${report.unpaidTransactions}'),
    );

    if (report.expenses.isNotEmpty) {
      bytes.addAll(_divider(generator));
      bytes.addAll(
        generator.safeText(
          'PENGELUARAN KASIR',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      );
      bytes.addAll(_divider(generator));
      for (final expense in report.expenses) {
        final time = DateFormat(
          'dd MMM HH:mm',
          'id_ID',
        ).format(expense.createdAt.toLocal());
        final category = _expenseLabels[expense.category] ?? expense.category;
        bytes.addAll(
          _detailText(
            generator,
            '$time | ${category.toUpperCase()}',
            bold: true,
          ),
        );
        bytes.addAll(
          _nameAmount(generator, expense.description, expense.amount),
        );
      }
      bytes.addAll(
        _nameAmount(
          generator,
          'TOTAL PENGELUARAN',
          report.expenses.fold(0, (sum, item) => sum + item.amount),
          bold: true,
        ),
      );
    }

    if (includeProducts) {
      bytes.addAll(generator.feed(1));
      bytes.addAll(_divider(generator));
      bytes.addAll(
        generator.safeText(
          'LAPORAN TUTUP KASIR',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      );
      bytes.addAll(
        generator.safeText(
          'PENJUALAN MENU',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      );
      if (report.isProvisional) {
        bytes.addAll(
          generator.safeText(
            'SEMENTARA - MENUNGGU SINKRONISASI',
            styles: const PosStyles(align: PosAlign.center, bold: true),
          ),
        );
      }
      bytes.addAll(_divider(generator));
      bytes.addAll(_section(generator, 'Informasi Shift'));
      bytes.addAll(
        _keyValue(
          generator,
          'Kasir',
          report.cashierName,
          alignValueRight: false,
        ),
      );
      bytes.addAll(
        _keyValue(
          generator,
          'Waktu Buka',
          _date(report.openedAt),
          alignValueRight: false,
        ),
      );
      bytes.addAll(
        _keyValue(
          generator,
          'Waktu Tutup',
          _date(report.closedAt),
          alignValueRight: false,
        ),
      );
      bytes.addAll(_divider(generator));
      bytes.addAll(_section(generator, 'Produk Terjual'));

      if (report.products.isEmpty) {
        bytes.addAll(generator.safeText('Tidak ada produk terjual.'));
      } else {
        for (final product in report.products) {
          bytes.addAll(_productLine(generator, product));
        }
      }
      bytes.addAll(_divider(generator));
      bytes.addAll(
        _keyValue(
          generator,
          'Total Produk',
          '${report.productQuantity}',
          bold: true,
        ),
      );
    }
    if (report.notes?.trim().isNotEmpty == true) {
      bytes.addAll(generator.feed(1));
      bytes.addAll(generator.safeText('Catatan: ${report.notes!.trim()}'));
    }
    bytes.addAll(generator.feed(3));
    bytes.addAll(generator.cut());
    return bytes;
  }
}

Future<PrintOutcome> printShiftCloseReport(
  ShiftCloseReport report, {
  bool includeProducts = true,
}) async {
  final printerService = PrinterService();
  final printer = await printerService.printerForReceipt();
  final paper = printer?.paper == '80' ? PaperSize.mm80 : PaperSize.mm58;
  final bytes = await ShiftCloseReportBuilder(
    report: report,
    paperSize: paper,
    driver: printer?.driver ?? 'generic1',
    includeProducts: includeProducts,
  ).build();
  return printerService.printReceiptBytes(
    bytes,
    jobLabel: 'Laporan tutup kasir',
  );
}

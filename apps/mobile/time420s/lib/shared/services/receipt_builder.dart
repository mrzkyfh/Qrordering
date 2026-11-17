import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import '../models/order.dart';
import '../models/enums.dart';
import 'printer_text.dart';

/// Gabungkan pembayaran per metode untuk ditampilkan pada struk.
///
/// Split bill dapat memiliki beberapa baris dengan metode yang sama. Struk
/// cukup menampilkan satu total per metode agar ringkas dan mudah direkonsiliasi.
Map<PaymentMethod, double> receiptPaymentBreakdown(Iterable<Payment> payments) {
  final result = <PaymentMethod, double>{};
  for (final payment in payments) {
    result.update(
      payment.method,
      (amount) => amount + payment.amount,
      ifAbsent: () => payment.amount,
    );
  }
  return result;
}

/// Compose ESC/POS commands untuk cetak struk thermal.
///
/// Mengikuti pengaturan struk yang di-set di owner-panel web
/// (`/admin/receipt` — tersimpan di `outlets.settings.receipt_*`).
///
/// Default 58mm (32 char). Bisa di-set ke 80mm via constructor.
class ReceiptBuilder {
  final OutletReceiptInfo outlet;
  final PaperSize paperSize;

  /// Profile driver lokal. `generic2`/`compact` memakai Font B sebagai
  /// fallback untuk printer thermal yang area cetaknya lebih sempit.
  final String driver;

  ReceiptBuilder({
    required this.outlet,
    this.paperSize = PaperSize.mm58,
    this.driver = 'generic1',
  });

  /// Jarak baris informasi header pada struk fisik.
  ///
  /// Font A thermal tingginya sekitar 24 dot. Preview memakai line-height 1,35,
  /// sehingga 34 dot memberi hasil yang lebih dekat dengan preview tanpa
  /// menambahkan satu baris kosong penuh di antara alamat, telepon, dan kota.
  static const int headerLineSpacingDots = 34;
  static const int headerSectionGapDots = 6;

  static const _esc = 0x1b;

  static List<int> _setLineSpacing(int dots) => [_esc, 0x33, dots];
  static List<int> _resetLineSpacing() => const [_esc, 0x32];
  static List<int> _feedDots(int dots) => [_esc, 0x4a, dots];

  // ── Logo struk (raster) — di-cache per (sumber+ukuran) agar tak proses ulang.
  static final Map<String, img.Image?> _logoCache = {};

  /// Siapkan logo untuk cetak thermal: ambil dari URL (upload owner-panel) bila
  /// ada, else aset bawaan `assets/images/logo.png`. Proses: ratakan alpha ke
  /// putih → grayscale → resize (normal 200px / full 370px; 58mm ≈ 384 dot).
  /// Di-cache; return null bila gagal (struk tetap tercetak tanpa logo).
  static Future<img.Image?> _loadLogo({String? url, bool full = false}) async {
    final width = full ? 370 : 200;
    final src = (url != null && url.trim().isNotEmpty) ? url.trim() : 'asset';
    final key = '$src@$width';
    if (_logoCache.containsKey(key)) return _logoCache[key];
    try {
      Uint8List? raw;
      if (src != 'asset') {
        final res = await http
            .get(Uri.parse(src))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) raw = res.bodyBytes;
      }
      raw ??= (await rootBundle.load(
        'assets/images/logo.png',
      )).buffer.asUint8List();
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        _logoCache[key] = null;
        return null;
      }
      // Ratakan transparansi ke putih (transparan → hitam bila tak diratakan).
      final flat = img.Image(width: decoded.width, height: decoded.height);
      img.fill(flat, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(flat, decoded);
      final out = img.copyResize(img.grayscale(flat), width: width);
      _logoCache[key] = out;
      return out;
    } catch (_) {
      _logoCache[key] = null;
      return null;
    }
  }

  static const _paymentLabels = {
    PaymentMethod.cash: 'Tunai',
    PaymentMethod.qris: 'QRIS',
    PaymentMethod.debit: 'Debit',
    PaymentMethod.credit: 'Kredit',
    PaymentMethod.ewallet: 'E-Wallet',
    PaymentMethod.transfer: 'Transfer',
  };

  /// Bangun struk komplet. Setiap section di-render conditional sesuai
  /// toggle dari outlet.settings.
  Future<List<int>> build({
    required Order order,
    PaymentMethod? paymentMethod,
    double? cashReceived,
    Map<PaymentMethod, double> paymentBreakdown = const {},
    String? cashierName,
    String? customerName,
    String? waiterName,
    String? documentTitle,
    List<String> documentNotes = const [],
    List<OrderItem>? documentItems,
    bool showFinancialSummary = true,
  }) async {
    final profile = await CapabilityProfile.load();
    final g = Generator(paperSize, profile);
    final cfg = outlet.receipt;
    final bytes = <int>[];
    final paidFromBreakdown = paymentBreakdown.values.fold<double>(
      0,
      (sum, amount) => sum + amount,
    );
    // Pada cetak tepat setelah pembayaran, objek order di UI dapat masih
    // merupakan snapshot sebelum RPC selesai dan belum memuat `payments`.
    // Kehadiran metode pembayaran berarti pemanggil sudah berhasil membayar;
    // breakdown tetap diperiksa terhadap total agar split parsial tidak keliru.
    final receiptIsFullyPaid =
        order.isFullyPaid ||
        paymentMethod != null ||
        paidFromBreakdown >= order.totalAmount - 0.01;
    final showOutletName = cfg.showOutletName || cfg.showBusinessName;
    final hasHeaderDetails =
        (cfg.showAddress && outlet.address.isNotEmpty) ||
        (cfg.showPhone && outlet.phone.isNotEmpty) ||
        (cfg.showCity && outlet.city.isNotEmpty) ||
        (cfg.showProvince && outlet.province.isNotEmpty) ||
        (cfg.showCountry && outlet.country.isNotEmpty) ||
        cfg.customHeaderFields.any(
          (field) => field.visible && field.label.isNotEmpty,
        ) ||
        (cfg.customHeader && cfg.customHeaderText.isNotEmpty);
    if (driver == 'generic2' || driver == 'compact') {
      bytes.addAll(g.setStyles(const PosStyles(fontType: PosFontType.fontB)));
    }

    // ── HEADER — Logo (raster ESC/POS) + outlet info ──────
    if (cfg.showLogo) {
      final logo = await _loadLogo(
        url: cfg.logoUrl,
        full: cfg.logoStyle == 'full',
      );
      if (logo != null) {
        bytes.addAll(g.image(logo)); // align center (default)
      }
      bytes.addAll(g.feed(1));
    }

    if (showOutletName) {
      bytes.addAll(
        g.safeText(
          outlet.name,
          styles: const PosStyles(
            align: PosAlign.center,
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size2,
          ),
        ),
      );
    }
    if (hasHeaderDetails) {
      // Nama outlet memakai ukuran dua kali. Beri ruang kecil sebelum informasi
      // kontak, lalu longgarkan setiap baris seperti line-height pada preview.
      if (showOutletName) {
        bytes.addAll(_feedDots(headerSectionGapDots));
      }
      bytes.addAll(_setLineSpacing(headerLineSpacingDots));
    }
    if (cfg.showAddress && outlet.address.isNotEmpty) {
      bytes.addAll(_wrappedText(g, outlet.address, align: PosAlign.center));
    }
    if (cfg.showPhone && outlet.phone.isNotEmpty) {
      bytes.addAll(
        g.safeText(
          'Telp: ${outlet.phone}',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    if (cfg.showCity && outlet.city.isNotEmpty) {
      bytes.addAll(_wrappedText(g, outlet.city, align: PosAlign.center));
    }
    if (cfg.showProvince && outlet.province.isNotEmpty) {
      bytes.addAll(_wrappedText(g, outlet.province, align: PosAlign.center));
    }
    if (cfg.showCountry && outlet.country.isNotEmpty) {
      bytes.addAll(_wrappedText(g, outlet.country, align: PosAlign.center));
    }
    // Custom header fields
    for (final f in cfg.customHeaderFields) {
      if (!f.visible || f.label.isEmpty) continue;
      final line = f.value.isEmpty ? f.label : '${f.label}: ${f.value}';
      bytes.addAll(_wrappedText(g, line, align: PosAlign.center));
    }

    // Custom header text (free text di tab Body)
    if (cfg.customHeader && cfg.customHeaderText.isNotEmpty) {
      bytes.addAll(
        g.safeText(
          cfg.customHeaderText,
          styles: PosStyles(align: _toPosAlign(cfg.customHeaderAlign)),
        ),
      );
    }

    if (hasHeaderDetails) {
      bytes.addAll(_resetLineSpacing());
    }
    // Preview memberi padding vertikal pada garis. Gunakan feed parsial supaya
    // hasil fisik lapang tetapi tidak sepanjang satu baris kosong tambahan.
    bytes.addAll(_feedDots(headerSectionGapDots));
    bytes.addAll(g.hr());
    bytes.addAll(_feedDots(headerSectionGapDots));

    // Order QR dapat dicetak ulang dari beberapa layar. Status belum dibayar
    // harus tetap terlihat meski pemanggil tidak mengirim judul secara khusus.
    final effectiveDocumentTitle = documentTitle?.trim().isNotEmpty == true
        ? documentTitle!.trim()
        : order.orderType == OrderType.selfOrder && !receiptIsFullyPaid
        ? 'ORDER QR - BELUM DIBAYAR'
        : null;
    // Judul dokumen khusus, misalnya STRUK VOID. Diletakkan sebelum metadata
    // agar tidak tertukar dengan struk penjualan biasa.
    if (effectiveDocumentTitle != null) {
      for (final line in wrapText(
        effectiveDocumentTitle.toUpperCase(),
        _fontAChars ~/ 2,
      )) {
        bytes.addAll(
          g.safeText(
            line,
            styles: const PosStyles(
              align: PosAlign.center,
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size2,
            ),
          ),
        );
      }
      bytes.addAll(g.hr());
    }

    final serviceBanner = _serviceBanner(
      order,
      showOrderType: cfg.showOrderType,
      showTable: cfg.showTable,
    );
    if (serviceBanner != null) {
      for (final line in wrapText(serviceBanner, _fontAChars)) {
        bytes.addAll(
          g.safeText(
            line,
            styles: const PosStyles(align: PosAlign.center, bold: true),
          ),
        );
      }
      bytes.addAll(g.hr());
    }

    // ── BODY — Order metadata ──────────────────────────────
    if (cfg.showOrderNumber) {
      bytes.addAll(
        _kv(
          g,
          'No Nota',
          order.orderNumber,
          valueBold: true,
          valueAlign: PosAlign.left,
        ),
      );
    }
    if (cfg.showOrderTime) {
      final dateStr = DateFormat(
        'dd/MM/yyyy HH:mm',
        'id_ID',
      ).format(order.createdAt.toLocal());
      bytes.addAll(_kv(g, 'Waktu', dateStr, valueAlign: PosAlign.left));
    }
    if (cfg.showCashierOrder &&
        order.orderType != OrderType.selfOrder &&
        cashierName != null &&
        cashierName.isNotEmpty) {
      bytes.addAll(
        _kv(g, 'Kasir Order', cashierName, valueAlign: PosAlign.left),
      );
    }
    if (cfg.showCashierPay && cashierName != null && cashierName.isNotEmpty) {
      bytes.addAll(
        _kv(g, 'Kasir Bayar', cashierName, valueAlign: PosAlign.left),
      );
    }
    if (cfg.showCustomer && customerName != null && customerName.isNotEmpty) {
      bytes.addAll(_kv(g, 'Customer', customerName, valueAlign: PosAlign.left));
    }
    if (cfg.showWaiter &&
        waiterName != null &&
        waiterName.isNotEmpty &&
        !(order.orderType == OrderType.selfOrder &&
            waiterName.trim() == cashierName?.trim())) {
      bytes.addAll(_kv(g, 'Dilayani', waiterName, valueAlign: PosAlign.left));
    }
    if (cfg.showOrderName &&
        order.customerName != null &&
        order.customerName!.isNotEmpty &&
        order.customerName!.trim() != customerName?.trim()) {
      bytes.addAll(
        _kv(g, 'Nama Order', order.customerName!, valueAlign: PosAlign.left),
      );
    }
    // Custom body fields
    for (final f in cfg.customBodyFields) {
      if (!f.visible || f.label.isEmpty) continue;
      bytes.addAll(_kv(g, f.label, f.value, valueAlign: PosAlign.left));
    }
    for (final note in documentNotes) {
      if (note.trim().isEmpty) continue;
      bytes.addAll(
        g.safeText(note.trim(), styles: const PosStyles(bold: true)),
      );
    }

    final customerOrderNote = order.customerOrderNote;
    if (customerOrderNote != null) {
      bytes.addAll(_noteSection(g, customerOrderNote));
    }

    bytes.addAll(g.hr());

    // ── Items ──────────────────────────────────────────────
    final renderedItems = documentItems ?? order.items;
    if (renderedItems != null && renderedItems.isNotEmpty) {
      for (final item in renderedItems) {
        final name = item.menuItem?.name ?? 'Item';
        final label = item.quantity > 1 ? '$name x${item.quantity}' : name;
        bytes.addAll(_itemAmount(g, label, _fmtMoney(item.subtotal)));
        // Extra/topping — tanpa ini customer bisa bingung kenapa harga item
        // beda dari harga menu dasar (subtotal item sudah termasuk extra).
        // Harga extra disertakan agar rinciannya transparan.
        var usedFontB = false;
        for (final opt in item.options) {
          final optionText = opt.price > 0
              ? '${opt.optionName} (+${_fmtMoney(opt.price)})'
              : opt.optionName;
          bytes.addAll(
            _wrappedText(
              g,
              optionText,
              fontType: PosFontType.fontB,
              firstLinePrefix: '  + ',
              continuationPrefix: '    ',
            ),
          );
          usedFontB = true;
        }
        if (item.notes != null && item.notes!.isNotEmpty) {
          bytes.addAll(
            _wrappedText(
              g,
              stripEmojiForPrinter(item.notes!),
              fontType: PosFontType.fontB,
              firstLinePrefix: '  Catatan: ',
              continuationPrefix: '    ',
            ),
          );
          usedFontB = true;
        }
        // `PosStyles.fontType` nullable → bila null Generator TIDAK mengirim
        // perintah font, sehingga Font B di atas "menempel" ke baris berikutnya
        // (item, subtotal, total ikut mengecil). Kembalikan eksplisit ke Font A.
        if (usedFontB) {
          bytes.addAll(
            g.setStyles(const PosStyles(fontType: PosFontType.fontA)),
          );
        }
      }
      bytes.addAll(g.hr());
    }

    // ── Totals ─────────────────────────────────────────────
    // Label dijaga pendek (muat di lebar kolom) — jumlah/rincian produk
    // sudah tampil di daftar item di atas, tak perlu diulang di sini.
    if (showFinancialSummary) {
      bytes.addAll(_kv(g, 'Subtotal', _fmtMoney(order.subtotal)));
      if (order.discountAmount > 0) {
        bytes.addAll(_kv(g, 'Diskon', '-${_fmtMoney(order.discountAmount)}'));
      }
      if (order.serviceCharge > 0) {
        final pct = outlet.serviceChargePercent > 0
            ? ' ${_fmtPct(outlet.serviceChargePercent)}%'
            : '';
        bytes.addAll(_kv(g, 'Service$pct', _fmtMoney(order.serviceCharge)));
      }
      if (order.taxAmount > 0 && !outlet.taxInclusive) {
        final pct = outlet.taxPercent > 0
            ? ' ${_fmtPct(outlet.taxPercent)}%'
            : '';
        bytes.addAll(
          _kv(g, '${outlet.taxName}$pct', _fmtMoney(order.taxAmount)),
        );
      }
      bytes.addAll(g.hr());
      // Baris TOTAL (emphasis, tinggi ganda). Label sengaja PENDEK ('TOTAL', 5
      // char) — 'Total Tagihan' (13 char) di kolom lebar-5 pada 58mm melipat ke
      // baris berikutnya sehingga nominal tak lagi sejajar. Kolom 5/7 sama seperti
      // _kv agar nominal segaris dengan Subtotal/Service/PPN/Tunai.
      bytes.addAll(
        g.row([
          PosColumn(
            text: 'TOTAL',
            width: 5,
            styles: const PosStyles(bold: true, height: PosTextSize.size2),
          ),
          PosColumn(
            text: _fmtMoney(order.totalAmount),
            width: 7,
            styles: const PosStyles(
              align: PosAlign.right,
              bold: true,
              height: PosTextSize.size2,
            ),
          ),
        ]),
      );
      bytes.addAll(g.hr());

      // ── Payment ────────────────────────────────────────────
      if (paymentBreakdown.isNotEmpty) {
        for (final entry in paymentBreakdown.entries) {
          final label = _paymentLabels[entry.key] ?? entry.key.value;
          bytes.addAll(_kv(g, label, _fmtMoney(entry.value)));
        }
      } else if (paymentMethod != null) {
        final label = _paymentLabels[paymentMethod] ?? paymentMethod.value;
        bytes.addAll(
          _kv(g, label, _fmtMoney(cashReceived ?? order.totalAmount)),
        );
        if (paymentMethod == PaymentMethod.cash && cashReceived != null) {
          final change = cashReceived - order.totalAmount;
          if (change > 0) {
            bytes.addAll(_kv(g, 'Kembali', _fmtMoney(change)));
          }
        }
      }

      // Tax inclusive notice
      if (outlet.taxInclusive && order.taxAmount > 0) {
        bytes.addAll(g.hr());
        bytes.addAll(
          g.safeText(
            'Harga Sudah Termasuk ${outlet.taxName}',
            styles: const PosStyles(align: PosAlign.center),
          ),
        );
        bytes.addAll(
          g.safeText(
            'Senilai ${_fmtMoney(order.taxAmount)}',
            styles: const PosStyles(align: PosAlign.center),
          ),
        );
      }
    }

    // ── FOOTER ─────────────────────────────────────────────
    if (cfg.footer.isNotEmpty) {
      bytes.addAll(g.hr());
      // Multi-line footer
      for (final line in cfg.footer.split('\n')) {
        bytes.addAll(
          g.safeText(line, styles: const PosStyles(align: PosAlign.center)),
        );
      }
    }
    bytes.addAll(compactFinalCut(g));

    return bytes;
  }

  // ─── Helpers ───────────────────────────────────────────

  // Lebar label maksimum di antara semua baris metadata & total ("Kasir Order",
  // "Kasir Bayar", "Jenis Order" = 11 karakter). Label di-pad ke lebar ini agar
  // titik dua SEJAJAR satu kolom, tidak mengambang mengikuti panjang label.
  static const _kvLabelWidth = 11;

  int get _fontAChars => paperSize == PaperSize.mm58
      ? 32
      : paperSize == PaperSize.mm72
      ? 42
      : 48;

  int get _fontBChars => paperSize == PaperSize.mm58
      ? 42
      : paperSize == PaperSize.mm72
      ? 56
      : 64;

  // Lebar riil hasil perhitungan Generator untuk kolom 8/12 dan 7/12.
  int get _itemNameChars => paperSize == PaperSize.mm58
      ? 20
      : paperSize == PaperSize.mm72
      ? 27
      : 31;

  int get _kvValueChars => paperSize == PaperSize.mm58
      ? 18
      : paperSize == PaperSize.mm72
      ? 24
      : 28;

  /// Format label kolom kiri: di-pad ke lebar tetap ([_kvLabelWidth]) lalu titik
  /// dua, agar titik dua SEJAJAR satu kolom di semua baris tanpa mengambang
  /// mengikuti panjang label. Dipisah sebagai fungsi murni agar bisa diuji.
  @visibleForTesting
  static String kvLabel(String key) => '${key.padRight(_kvLabelWidth)}:';

  /// Bungkus pada batas kata agar printer tidak meninggalkan satu-dua huruf
  /// sendirian di baris berikutnya. Kata yang memang lebih panjang dari lebar
  /// tetap dipecah aman supaya tidak melewati area cetak.
  @visibleForTesting
  static List<String> wrapText(String value, int width) {
    return wrapPrinterText(value, width);
  }

  String? _serviceBanner(
    Order order, {
    required bool showOrderType,
    required bool showTable,
  }) {
    final parts = <String>[];
    if (showOrderType) {
      parts.add(switch (order.orderType) {
        OrderType.dineIn => 'MAKAN DI TEMPAT',
        OrderType.takeaway => 'BAWA PULANG',
        OrderType.selfOrder => switch (order.customerServiceMode) {
          'dine_in' => 'MAKAN DI TEMPAT',
          'pickup' => 'BAWA PULANG',
          _ => 'ORDER QR',
        },
      });
    }
    if (showTable && order.shouldDisplayTable) {
      parts.add('MEJA ${order.tableNumber!.trim().toUpperCase()}');
    }
    return parts.isEmpty ? null : parts.join(' - ');
  }

  List<int> _noteSection(Generator g, String note) {
    final bytes = <int>[
      ...g.safeText(
        printerSectionTitle('CATATAN ORDER', _fontAChars),
        styles: const PosStyles(bold: true),
      ),
    ];
    for (final logicalLine in note.split('\n')) {
      if (logicalLine.trim().isEmpty) continue;
      final clean = stripEmojiForPrinter(logicalLine.trim()).toUpperCase();
      for (final line in wrapText(clean, _fontAChars)) {
        bytes.addAll(g.safeText(line, styles: const PosStyles(bold: true)));
      }
    }
    return bytes;
  }

  List<int> _wrappedText(
    Generator g,
    String value, {
    PosAlign align = PosAlign.left,
    PosFontType? fontType,
    String firstLinePrefix = '',
    String continuationPrefix = '',
  }) {
    final effectiveFont =
        fontType ??
        ((driver == 'generic2' || driver == 'compact')
            ? PosFontType.fontB
            : PosFontType.fontA);
    final chars = effectiveFont == PosFontType.fontB
        ? _fontBChars
        : _fontAChars;
    final bytes = <int>[];
    final firstWidth = chars - firstLinePrefix.length;
    final continuationWidth = chars - continuationPrefix.length;
    final firstPass = wrapText(value, firstWidth);
    for (var index = 0; index < firstPass.length; index++) {
      final prefix = index == 0 ? firstLinePrefix : continuationPrefix;
      final available = index == 0 ? firstWidth : continuationWidth;
      for (final line in wrapText(firstPass[index], available)) {
        bytes.addAll(
          g.safeText(
            '$prefix$line',
            styles: PosStyles(align: align, fontType: effectiveFont),
          ),
        );
      }
    }
    return bytes;
  }

  List<int> _itemAmount(Generator g, String name, String amount) {
    final names = wrapText(name, _itemNameChars);
    final bytes = <int>[];
    for (var index = 0; index < names.length; index++) {
      bytes.addAll(
        g.row([
          PosColumn(text: names[index], width: 8),
          PosColumn(
            text: index == 0 ? amount : '',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    return bytes;
  }

  // Kolom label 5 / nilai 7 (bukan 6/6): di kertas 58mm (32 kolom) kolom nilai
  // jadi ~19 karakter sehingga "12/07/2026 18:03" (16) muat utuh tanpa terpotong
  // ke baris berikutnya. Nilai rata kanan agar sejajar seperti daftar item.
  List<int> _kv(
    Generator g,
    String key,
    String value, {
    bool valueBold = false,
    PosAlign valueAlign = PosAlign.right,
  }) {
    final values = wrapText(value, _kvValueChars);
    final bytes = <int>[];
    for (var index = 0; index < values.length; index++) {
      bytes.addAll(
        g.row([
          PosColumn(text: index == 0 ? kvLabel(key) : '', width: 5),
          PosColumn(
            text: values[index],
            width: 7,
            styles: PosStyles(bold: valueBold, align: valueAlign),
          ),
        ]),
      );
    }
    return bytes;
  }

  PosAlign _toPosAlign(String align) => switch (align) {
    'left' => PosAlign.left,
    'right' => PosAlign.right,
    _ => PosAlign.center,
  };

  static final _moneyFormat = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp',
    decimalDigits: 0,
  );

  String _fmtMoney(double v) => _moneyFormat.format(v);

  /// Persen tanpa desimal jika bulat (10 bukan 10.0), max 2 desimal.
  String _fmtPct(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  static Uint8List toUint8List(List<int> bytes) => Uint8List.fromList(bytes);
}

// ─── Models ───────────────────────────────────────────────────────────────────

/// Custom field di header/body struk yang user define di web settings.
class ReceiptCustomField {
  final String id;
  final String label;
  final String value;
  final bool visible;

  const ReceiptCustomField({
    required this.id,
    required this.label,
    required this.value,
    required this.visible,
  });

  factory ReceiptCustomField.fromMap(Map<String, dynamic> m) =>
      ReceiptCustomField(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        value: m['value'] as String? ?? '',
        visible: m['visible'] as bool? ?? true,
      );
}

/// Konfigurasi tampilan struk — sinkron dengan toggle di
/// `apps/owner-panel/src/pages/admin/ReceiptSettings.tsx`.
class ReceiptConfig {
  final bool showLogo;
  final String logoStyle;
  final String? logoUrl;
  final bool showBusinessName;
  final bool showOutletName;
  final bool showAddress;
  final bool showPhone;
  final bool showCity;
  final bool showProvince;
  final bool showCountry;
  final List<ReceiptCustomField> customHeaderFields;
  final bool customHeader;
  final String customHeaderText;
  final String customHeaderAlign;
  final bool showOrderNumber;
  final bool showOrderTime;
  final bool showCashierOrder;
  final bool showCashierPay;
  final bool showCustomer;
  final bool showWaiter;
  final bool showOrderType;
  final bool showOrderName;
  final bool showTable;
  final List<ReceiptCustomField> customBodyFields;
  final String footer;
  final bool limitPrint;

  const ReceiptConfig({
    this.showLogo = true,
    this.logoStyle = 'normal',
    this.logoUrl,
    this.showBusinessName = false,
    this.showOutletName = true,
    this.showAddress = true,
    this.showPhone = false,
    this.showCity = false,
    this.showProvince = false,
    this.showCountry = false,
    this.customHeaderFields = const [],
    this.customHeader = false,
    this.customHeaderText = '',
    this.customHeaderAlign = 'center',
    this.showOrderNumber = true,
    this.showOrderTime = true,
    this.showCashierOrder = true,
    this.showCashierPay = true,
    this.showCustomer = true,
    this.showWaiter = true,
    this.showOrderType = true,
    this.showOrderName = true,
    this.showTable = true,
    this.customBodyFields = const [],
    this.footer = '',
    this.limitPrint = false,
  });

  factory ReceiptConfig.fromSettings(Map<String, dynamic>? s) {
    if (s == null) return const ReceiptConfig();
    List<ReceiptCustomField> parseFields(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(ReceiptCustomField.fromMap)
          .toList();
    }

    return ReceiptConfig(
      showLogo: s['receipt_show_logo'] as bool? ?? true,
      logoStyle: s['receipt_logo_style'] as String? ?? 'normal',
      logoUrl: s['receipt_logo_url'] as String?,
      showBusinessName: s['receipt_show_business_name'] as bool? ?? false,
      showOutletName: s['receipt_show_outlet_name'] as bool? ?? true,
      showAddress: s['receipt_show_address'] as bool? ?? true,
      showPhone: s['receipt_show_phone'] as bool? ?? false,
      showCity: s['receipt_show_city'] as bool? ?? false,
      showProvince: s['receipt_show_province'] as bool? ?? false,
      showCountry: s['receipt_show_country'] as bool? ?? false,
      customHeaderFields: parseFields(s['receipt_custom_header_fields']),
      customHeader: s['receipt_custom_header'] as bool? ?? false,
      customHeaderText: s['receipt_custom_header_text'] as String? ?? '',
      customHeaderAlign:
          s['receipt_custom_header_align'] as String? ?? 'center',
      showOrderNumber: s['receipt_show_order_number'] as bool? ?? true,
      showOrderTime: s['receipt_show_order_time'] as bool? ?? true,
      showCashierOrder: s['receipt_show_cashier'] as bool? ?? true,
      showCashierPay: s['receipt_show_cashier_pay'] as bool? ?? true,
      showCustomer: s['receipt_show_customer'] as bool? ?? true,
      showWaiter: s['receipt_show_waiter'] as bool? ?? true,
      showOrderType: s['receipt_show_order_type'] as bool? ?? true,
      showOrderName: s['receipt_show_order_name'] as bool? ?? true,
      showTable: s['receipt_show_table'] as bool? ?? true,
      customBodyFields: parseFields(s['receipt_custom_body_fields']),
      footer: s['receipt_footer'] as String? ?? '',
      limitPrint: s['receipt_limit_print'] as bool? ?? false,
    );
  }
}

/// Data outlet untuk header struk + konfigurasi tampilan.
class OutletReceiptInfo {
  final String name;
  final String address;
  final String phone;
  final String city;
  final String province;
  final String country;
  final String taxName;
  final double taxPercent;
  final bool taxInclusive;
  final double serviceChargePercent;
  final ReceiptConfig receipt;

  const OutletReceiptInfo({
    required this.name,
    this.address = '',
    this.phone = '',
    this.city = '',
    this.province = '',
    this.country = '',
    this.taxName = 'PPN',
    this.taxPercent = 0,
    this.taxInclusive = false,
    this.serviceChargePercent = 0,
    this.receipt = const ReceiptConfig(),
  });

  factory OutletReceiptInfo.fromMap(Map<String, dynamic> map) {
    final s = map['settings'] as Map<String, dynamic>?;
    return OutletReceiptInfo(
      name: map['name'] as String? ?? '',
      address: map['address'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      city: map['city'] as String? ?? '',
      // Provinsi & Negara adalah teks bebas dari settings (bukan kolom outlet).
      province: s?['receipt_province'] as String? ?? '',
      country: s?['receipt_country'] as String? ?? '',
      taxName: s?['tax_name'] as String? ?? 'PPN',
      taxPercent: (s?['tax_percent'] as num?)?.toDouble() ?? 0,
      taxInclusive: s?['tax_inclusive'] as bool? ?? false,
      serviceChargePercent:
          (s?['service_charge_percent'] as num?)?.toDouble() ?? 0,
      receipt: ReceiptConfig.fromSettings(s),
    );
  }
}

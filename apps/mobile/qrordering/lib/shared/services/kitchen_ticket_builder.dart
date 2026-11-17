import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:intl/intl.dart';
import '../models/order.dart';
import '../models/enums.dart';
import 'printer_text.dart';

@visibleForTesting
String voidKitchenTitle(String stationName) {
  var name = stationName.trim();
  if (name.isEmpty || name.toLowerCase() == 'dapur') return 'VOID Dapur';
  if (name.toLowerCase().startsWith('dapur -')) {
    name = name.substring(name.indexOf('-') + 1).trim();
  }
  return name.isEmpty ? 'VOID Dapur' : 'VOID Dapur - ${name.toUpperCase()}';
}

@visibleForTesting
String voidKitchenMetadataLine(String label, String value) =>
    '${label.padRight(9)}: $value';

@visibleForTesting
String kitchenTitle(String stationName) {
  final name = stationName.trim();
  if (name.isEmpty || name.toLowerCase() == 'dapur') return 'DAPUR';
  if (name.toLowerCase().startsWith('dapur -')) return name.toUpperCase();
  return 'DAPUR - ${name.toUpperCase()}';
}

@visibleForTesting
String kitchenMetadataLine(String label, String value) =>
    '${label.padRight(12)}: $value';

@visibleForTesting
String kitchenOrderTypeLabel(OrderType type) => switch (type) {
  OrderType.dineIn => 'Dine In',
  OrderType.takeaway => 'Bawa Pulang',
  OrderType.selfOrder => 'Order QR',
};

@visibleForTesting
String kitchenOrderTypeLabelForOrder(Order order) =>
    order.operationalOrderTypeLabel;

@visibleForTesting
String kitchenQrOrderTypeLabel(Order order) =>
    switch (order.customerServiceMode) {
      'dine_in' => 'QR Order (Makan di Tempat)',
      'pickup' => 'QR Order (Bawa Pulang)',
      _ => 'QR Order',
    };

/// Satu stasiun cetak (mis. Dapur, Bar). Owner mendefinisikan di owner-panel,
/// tersimpan di `outlets.settings.print_stations`.
class PrintStation {
  final String id;
  final String name;
  const PrintStation({required this.id, required this.name});

  factory PrintStation.fromMap(Map<String, dynamic> m) => PrintStation(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? '',
  );
}

/// Konfigurasi routing tiket per-bagian:
///   - daftar stasiun (Dapur, Bar, dll)
///   - peta kategori → stasiun (item kategori X dicetak ke stasiun Y)
///
/// Sinkron dengan owner-panel (`outlets.settings`):
///   print_stations:         daftar stasiun [id, name]
///   print_category_station: peta category_id ke station_id
class PrintStationConfig {
  final List<PrintStation> stations;
  final Map<String, String> categoryStation; // category_id -> station_id
  final Set<String> excludedCategoryIds;

  const PrintStationConfig({
    this.stations = const [],
    this.categoryStation = const {},
    this.excludedCategoryIds = const {},
  });

  bool get isEnabled =>
      stations.isNotEmpty &&
      (categoryStation.isNotEmpty || excludedCategoryIds.isNotEmpty);

  PrintStation? stationById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final station in stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  Set<String> categoryIdsForStation(String? id) => categoryStation.entries
      .where((entry) => entry.value == id)
      .map((entry) => entry.key)
      .toSet();

  factory PrintStationConfig.fromSettings(Map<String, dynamic>? s) {
    if (s == null) return const PrintStationConfig();
    final rawStations = s['print_stations'];
    final stations = rawStations is List
        ? rawStations
              .whereType<Map<String, dynamic>>()
              .map(PrintStation.fromMap)
              .where((st) => st.id.isNotEmpty && st.name.isNotEmpty)
              .toList()
        : <PrintStation>[];

    final rawMap = s['print_category_station'];
    final map = <String, String>{};
    if (rawMap is Map) {
      rawMap.forEach((k, v) {
        if (k is String && v is String && k.isNotEmpty && v.isNotEmpty) {
          map[k] = v;
        }
      });
    }
    final rawExcluded = s['print_excluded_categories'];
    final excluded = rawExcluded is List
        ? rawExcluded
              .map((value) => value.toString())
              .where((id) => id.isNotEmpty)
              .toSet()
        : <String>{};
    return PrintStationConfig(
      stations: stations,
      categoryStation: map,
      excludedCategoryIds: excluded,
    );
  }

  /// Kelompokkan item order per stasiun (berdasarkan kategori menu).
  /// Item tanpa pemetaan kategori → diabaikan (tidak masuk tiket manapun).
  /// Mengembalikan urutan sesuai daftar `stations`.
  List<({PrintStation station, List<OrderItem> items})> groupByStation(
    List<OrderItem> items,
  ) {
    final byStation = <String, List<OrderItem>>{};
    for (final it in items) {
      final catId = it.menuItem?.categoryId;
      if (catId == null) continue;
      final stationId = categoryStation[catId];
      if (stationId == null) continue;
      byStation.putIfAbsent(stationId, () => []).add(it);
    }
    final result = <({PrintStation station, List<OrderItem> items})>[];
    for (final st in stations) {
      final list = byStation[st.id];
      if (list != null && list.isNotEmpty) {
        result.add((station: st, items: list));
      }
    }
    return result;
  }
}

/// Compose ESC/POS untuk **tiket dapur/bar** — TANPA harga. Fokus: nama item,
/// jumlah, catatan, meja, waktu — huruf besar agar mudah dibaca di stasiun.
class KitchenTicketBuilder {
  final PaperSize paperSize;
  final String driver;
  KitchenTicketBuilder({
    this.paperSize = PaperSize.mm58,
    this.driver = 'generic1',
  });

  String _serviceBanner(Order order) {
    final parts = <String>[
      switch (order.orderType) {
        OrderType.dineIn => 'MAKAN DI TEMPAT',
        OrderType.takeaway => 'BAWA PULANG',
        OrderType.selfOrder => switch (order.customerServiceMode) {
          'dine_in' => 'MAKAN DI TEMPAT',
          'pickup' => 'BAWA PULANG',
          _ => 'ORDER QR',
        },
      },
    ];
    if (order.tableNumber?.trim().isNotEmpty == true &&
        order.orderType != OrderType.takeaway) {
      parts.add('MEJA ${order.tableNumber!.trim().toUpperCase()}');
    }
    return parts.join(' - ');
  }

  List<int> _noteBlock(Generator generator, String note, PosStyles styles) {
    final bytes = <int>[
      ...generator.safeText(
        printerSectionTitle('CATATAN ORDER', 32),
        styles: styles,
      ),
    ];
    for (final logicalLine in note.split('\n')) {
      if (logicalLine.trim().isEmpty) continue;
      final clean = stripEmojiForPrinter(logicalLine.trim()).toUpperCase();
      for (final line in wrapPrinterText(clean, 32)) {
        bytes.addAll(generator.safeText(line, styles: styles));
      }
    }
    return bytes;
  }

  /// Tiket tes singkat untuk satu printer (dipakai tombol "Tes" per printer).
  Future<List<int>> buildTest(String printerLabel) async {
    final profile = await CapabilityProfile.load();
    final g = Generator(paperSize, profile);
    final bytes = <int>[];
    if (driver == 'generic2' || driver == 'compact') {
      bytes.addAll(g.setStyles(const PosStyles(fontType: PosFontType.fontB)));
    }
    bytes.addAll(
      g.safeText(
        'TES PRINT',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(g.hr());
    bytes.addAll(
      g.safeText(printerLabel, styles: const PosStyles(align: PosAlign.center)),
    );
    bytes.addAll(
      g.safeText(
        DateFormat('dd/MM/yyyy HH:mm', 'id_ID').format(DateTime.now()),
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(compactFinalCut(g));
    return bytes;
  }

  Future<List<int>> build({
    required Order order,
    required String stationName,
    required List<OrderItem> items,
    required DateTime printedAt,
    String? printedBy,
  }) async {
    final profile = await CapabilityProfile.load();
    final g = Generator(paperSize, profile);
    final bytes = <int>[];
    const kitchenFont = PosStyles(fontType: PosFontType.fontA);
    const kitchenItemFont = PosStyles(fontType: PosFontType.fontA, bold: true);
    const centeredKitchenFont = PosStyles(
      align: PosAlign.center,
      fontType: PosFontType.fontA,
    );
    const kitchenTitleFont = PosStyles(
      align: PosAlign.center,
      fontType: PosFontType.fontA,
      bold: true,
      height: PosTextSize.size2,
    );
    const compactKitchenTitleFont = PosStyles(
      align: PosAlign.center,
      fontType: PosFontType.fontA,
      bold: true,
    );
    final isQrOrder = order.orderType == OrderType.selfOrder;

    // Tiket QR mengikuti format operasional yang ringkas: judul normal agar
    // kategori panjang tetap muat pada kertas 58 mm. Tiket kasir biasa tetap
    // memakai judul besar yang sudah digunakan sebelumnya.
    bytes.addAll(
      g.safeText(
        kitchenTitle(stationName),
        styles: isQrOrder ? compactKitchenTitleFont : kitchenTitleFont,
      ),
    );
    for (final line in wrapPrinterText(_serviceBanner(order), 32)) {
      bytes.addAll(
        g.safeText(
          line,
          styles: const PosStyles(
            align: PosAlign.center,
            fontType: PosFontType.fontA,
            bold: true,
          ),
        ),
      );
    }
    bytes.addAll(g.hr(ch: '-'));

    final orderTime = DateFormat(
      'dd MMM yy HH:mm',
      'id_ID',
    ).format(order.createdAt.toLocal());
    bytes.addAll(
      g.safeText(
        kitchenMetadataLine('No Nota', order.orderNumber),
        styles: kitchenFont,
      ),
    );
    bytes.addAll(
      g.safeText(kitchenMetadataLine('Waktu', orderTime), styles: kitchenFont),
    );
    final customerName = order.customerName?.trim().isNotEmpty == true
        ? order.customerName!.trim()
        : '-';
    if (isQrOrder) {
      bytes.addAll(
        g.safeText(
          kitchenMetadataLine('Order', 'Pesanan QR'),
          styles: kitchenFont,
        ),
      );
      bytes.addAll(
        g.safeText(
          kitchenMetadataLine('Customer', customerName),
          styles: kitchenFont,
        ),
      );
    } else {
      bytes.addAll(
        g.safeText(
          kitchenMetadataLine('Order', customerName),
          styles: kitchenFont,
        ),
      );
    }

    final customerOrderNote = order.customerOrderNote;
    if (customerOrderNote != null) {
      bytes.addAll(_noteBlock(g, customerOrderNote, kitchenItemFont));
    }
    bytes.addAll(g.hr(ch: '-'));

    // Item tetap tanpa harga dan menggunakan huruf kapital seperti tiket contoh.
    for (final it in items) {
      final name = it.menuItem?.name.trim().isNotEmpty == true
          ? it.menuItem!.name.trim()
          : 'ITEM';
      bytes.addAll(
        g.safeText(
          '${it.quantity} ${name.toUpperCase()}',
          styles: kitchenItemFont,
        ),
      );
      for (final opt in it.options) {
        bytes.addAll(
          g.safeText(
            isQrOrder
                ? '  + ${it.quantity} ${opt.optionName.toUpperCase()}'
                : '  + ${opt.optionName.toUpperCase()}',
            styles: kitchenFont,
          ),
        );
      }
      if (it.notes?.trim().isNotEmpty == true) {
        for (final line in it.notes!.trim().split('\n')) {
          if (line.trim().isEmpty) continue;
          bytes.addAll(
            g.safeText(
              isQrOrder
                  ? '  > ${stripEmojiForPrinter(line.trim())}'
                  : '  * ${stripEmojiForPrinter(line.trim())}',
              styles: kitchenFont,
            ),
          );
        }
      }
    }

    if (isQrOrder) bytes.addAll(g.hr(ch: '='));

    final printTime = DateFormat(
      'dd MMM yy HH:mm',
      'id_ID',
    ).format(printedAt.toLocal());
    bytes.addAll(g.feed(isQrOrder ? 1 : 3));
    bytes.addAll(g.safeText(printTime, styles: centeredKitchenFont));
    bytes.addAll(
      g.safeText(
        'dicetak: ${printedBy?.trim().isNotEmpty == true
            ? printedBy!.trim()
            : isQrOrder
            ? 'Sistem'
            : '-'}',
        styles: centeredKitchenFont,
      ),
    );
    bytes.addAll(compactFinalCut(g));
    return bytes;
  }

  /// Tiket pembatalan dapur dibuat sengaja ringkas agar mudah dibedakan dari
  /// tiket order baru. Bentuknya mengikuti contoh operasional pengguna:
  /// judul Void, metadata rata kiri, item tanpa harga, lalu waktu dan pencetak.
  Future<List<int>> buildVoid({
    required Order order,
    required String stationName,
    required List<OrderItem> items,
    required DateTime printedAt,
    String? printedBy,
  }) async {
    final profile = await CapabilityProfile.load();
    final g = Generator(paperSize, profile);
    final bytes = <int>[];
    const kitchenFont = PosStyles(fontType: PosFontType.fontA);
    const kitchenItemFont = PosStyles(fontType: PosFontType.fontA, bold: true);
    const centeredKitchenFont = PosStyles(
      align: PosAlign.center,
      fontType: PosFontType.fontA,
    );
    const kitchenTitleFont = PosStyles(
      align: PosAlign.center,
      fontType: PosFontType.fontA,
      bold: true,
      height: PosTextSize.size2,
    );

    bytes.addAll(
      g.safeText(voidKitchenTitle(stationName), styles: kitchenTitleFont),
    );
    bytes.addAll(g.feed(1));

    final time = DateFormat(
      'dd MMM yy HH:mm',
      'id_ID',
    ).format(printedAt.toLocal());
    bytes.addAll(
      g.safeText(
        voidKitchenMetadataLine('No Nota', order.orderNumber),
        styles: kitchenFont,
      ),
    );
    bytes.addAll(
      g.safeText(voidKitchenMetadataLine('Waktu', time), styles: kitchenFont),
    );
    bytes.addAll(
      g.safeText(
        voidKitchenMetadataLine(
          'Order',
          order.customerName?.trim().isNotEmpty == true
              ? order.customerName!.trim()
              : '-',
        ),
        styles: kitchenFont,
      ),
    );
    bytes.addAll(g.feed(1));

    for (final item in items) {
      final name = item.menuItem?.name.trim().isNotEmpty == true
          ? item.menuItem!.name.trim()
          : 'ITEM';
      bytes.addAll(
        g.safeText(
          '${item.quantity} ${name.toUpperCase()}',
          styles: kitchenItemFont,
        ),
      );
      for (final option in item.options) {
        bytes.addAll(
          g.safeText(
            '  + ${option.optionName.toUpperCase()}',
            styles: kitchenFont,
          ),
        );
      }
      if (item.notes?.trim().isNotEmpty == true) {
        bytes.addAll(
          g.safeText('  * ${item.notes!.trim()}', styles: kitchenFont),
        );
      }
    }

    bytes.addAll(g.feed(3));
    bytes.addAll(g.safeText(time, styles: centeredKitchenFont));
    bytes.addAll(
      g.safeText(
        'dicetak: ${printedBy?.trim().isNotEmpty == true ? printedBy!.trim() : '-'}',
        styles: centeredKitchenFont,
      ),
    );
    bytes.addAll(compactFinalCut(g));
    return bytes;
  }
}

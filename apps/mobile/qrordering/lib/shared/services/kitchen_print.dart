import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show PaperSize;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/order.dart';
import 'printer_service.dart';
import 'kitchen_ticket_builder.dart';
import '../../features/pos/data/datasources/pos_datasource.dart';

/// Trigger autoprint (model device-centric ala Majoo).
enum KitchenTrigger { order, qrOrder, bayar, voidOrder }

/// Ringkasan hasil pengiriman tiket ke seluruh printer dapur yang sesuai.
///
/// Tiket yang gagal dikirim langsung tetap masuk antrean lokal PrinterService,
/// sehingga dapat dicoba kembali dari halaman pengaturan printer.
class KitchenPrintResult {
  final int printed;
  final int queued;
  final String? skippedReason;

  const KitchenPrintResult({
    this.printed = 0,
    this.queued = 0,
    this.skippedReason,
  });

  bool get hasPrinted => printed > 0;
  bool get hasQueued => queued > 0;
  bool get wasSkipped => printed == 0 && queued == 0;
}

class PrinterRoutingDiagnostics {
  final List<String> warnings;
  final List<String> errors;

  const PrinterRoutingDiagnostics({
    this.warnings = const [],
    this.errors = const [],
  });

  bool get healthy => errors.isEmpty;
}

Future<bool> claimKitchenPrint(String orderId, {String? deviceId}) async {
  final owner = deviceId ?? await PrinterService().devicePrintId();
  final result = await Supabase.instance.client.rpc(
    'claim_kitchen_print',
    params: {'p_order_id': orderId, 'p_device_id': owner},
  );
  return result == true;
}

Future<bool> renewKitchenPrintClaim(String orderId, {String? deviceId}) async {
  final owner = deviceId ?? await PrinterService().devicePrintId();
  final result = await Supabase.instance.client.rpc(
    'renew_kitchen_print_claim',
    params: {'p_order_id': orderId, 'p_device_id': owner},
  );
  return result == true;
}

Future<bool> deferKitchenPrintClaim(String orderId, {String? deviceId}) async {
  final owner = deviceId ?? await PrinterService().devicePrintId();
  final result = await Supabase.instance.client.rpc(
    'defer_kitchen_print_claim',
    params: {'p_order_id': orderId, 'p_device_id': owner},
  );
  return result == true;
}

Future<bool> completeKitchenPrintClaim(
  String orderId, {
  String? deviceId,
}) async {
  final owner = deviceId ?? await PrinterService().devicePrintId();
  final result = await Supabase.instance.client.rpc(
    'complete_kitchen_print',
    params: {'p_order_id': orderId, 'p_device_id': owner},
  );
  return result == true;
}

Future<bool> releaseKitchenPrintClaim(
  String orderId, {
  String? deviceId,
}) async {
  final owner = deviceId ?? await PrinterService().devicePrintId();
  final result = await Supabase.instance.client.rpc(
    'release_kitchen_print_claim',
    params: {'p_order_id': orderId, 'p_device_id': owner},
  );
  return result == true;
}

/// Periksa apakah routing station outlet benar-benar memiliki tujuan printer.
/// Tidak mengubah setting apa pun; mobile hanya membaca konfigurasi Owner Panel.
Future<PrinterRoutingDiagnostics> loadPrinterRoutingDiagnostics(
  String outletId,
) async {
  if (outletId.isEmpty) {
    return const PrinterRoutingDiagnostics(
      errors: ['Outlet perangkat belum teridentifikasi'],
    );
  }
  try {
    final client = Supabase.instance.client;
    final outlet = await client
        .from('outlets')
        .select('settings')
        .eq('id', outletId)
        .single();
    final settings = (outlet['settings'] as Map?)?.cast<String, dynamic>();
    final config = PrintStationConfig.fromSettings(settings);
    final printers = await PrinterService().kitchenPrinters();

    if (!config.isEnabled) {
      return PrinterRoutingDiagnostics(
        warnings: [
          printers.isEmpty
              ? 'Belum ada printer dapur aktif'
              : 'Routing station belum aktif; printer memakai mapping lokal',
        ],
      );
    }

    final categories = await client
        .from('menu_categories')
        .select('id, name')
        .eq('outlet_id', outletId)
        .eq('is_active', true);
    final categoryNames = <String, String>{
      for (final row in (categories as List))
        row['id'] as String: row['name'] as String? ?? 'Kategori',
    };
    final errors = <String>[];
    final warnings = <String>[];
    for (final entry in categoryNames.entries) {
      if (!config.categoryStation.containsKey(entry.key) &&
          !config.excludedCategoryIds.contains(entry.key)) {
        errors.add('Kategori ${entry.value} belum dipetakan ke station');
      }
    }
    for (final station in config.stations) {
      if (!printers.any((p) => p.effectiveStationIds.contains(station.id))) {
        errors.add('Station ${station.name} belum memiliki printer');
      }
    }
    for (final printer in printers) {
      for (final stationId in printer.effectiveStationIds) {
        if (config.stationById(stationId) == null) {
          warnings.add(
            '${printer.name} terikat ke station yang sudah dihapus ($stationId)',
          );
        }
      }
    }
    if (printers.isEmpty) errors.add('Belum ada printer dapur aktif');
    return PrinterRoutingDiagnostics(warnings: warnings, errors: errors);
  } catch (_) {
    return const PrinterRoutingDiagnostics(
      errors: ['Diagnostik routing gagal dimuat; cek koneksi internet'],
    );
  }
}

/// Apakah printer ini harus mencetak untuk trigger tsb (atau force/manual).
@visibleForTesting
bool kitchenPrinterMatches(SavedPrinter p, KitchenTrigger? trigger) {
  if (!p.dapurEnabled) return false; // peran Dapur dimatikan
  if (trigger == null) return true; // force/manual reprint
  return switch (trigger) {
    KitchenTrigger.order => p.autoOrder,
    KitchenTrigger.qrOrder => p.autoQrOrder,
    KitchenTrigger.bayar => p.autoBayar,
    KitchenTrigger.voidOrder => p.autoVoid,
  };
}

/// Batasi reprint manual ke satu printer yang dipilih. Initial print tetap
/// memakai seluruh printer yang cocok dengan trigger konfigurasi.
@visibleForTesting
List<SavedPrinter> kitchenPrintersForIntent(
  Iterable<SavedPrinter> printers, {
  required KitchenTrigger? trigger,
  String? targetPrinterId,
}) {
  return printers
      .where(
        (printer) =>
            kitchenPrinterMatches(printer, trigger) &&
            (targetPrinterId == null || printer.id == targetPrinterId),
      )
      .toList();
}

/// Item yang relevan untuk satu printer dapur: kategori kosong = semua kategori.
/// Item tanpa kategori dikenal (menuItem null / category_id null) ikut dicetak
/// agar tidak hilang diam-diam dari tiket dapur.
@visibleForTesting
List<OrderItem> kitchenItemsForPrinter(SavedPrinter p, List<OrderItem> items) {
  return kitchenItemsForPrinterWithStations(p, items);
}

@visibleForTesting
List<OrderItem> kitchenItemsForPrinterWithStations(
  SavedPrinter p,
  List<OrderItem> items, {
  PrintStationConfig? stationConfig,
}) {
  if (stationConfig != null && p.effectiveStationIds.isNotEmpty) {
    final categories = p.effectiveStationIds
        .expand(stationConfig.categoryIdsForStation)
        .toSet();
    return items
        .where((it) => categories.contains(it.menuItem?.categoryId))
        .toList();
  }
  if (p.categories.isEmpty) return items;
  return items
      .where(
        (it) =>
            it.menuItem?.categoryId == null ||
            p.categories.contains(it.menuItem?.categoryId),
      )
      .toList();
}

/// Kelompok tiket untuk setiap stasiun yang dipilih pada satu printer fisik.
/// Urutannya mengikuti urutan stasiun dari Owner Panel agar hasil cetak selalu
/// konsisten (mis. Bar → Kebab → Kopi).
@visibleForTesting
List<({PrintStation station, List<OrderItem> items})>
kitchenStationBatchesForPrinter(
  SavedPrinter printer,
  List<OrderItem> items,
  PrintStationConfig config,
) {
  final selected = printer.effectiveStationIds.toSet();
  if (selected.isEmpty) return const [];
  final batches = <({PrintStation station, List<OrderItem> items})>[];
  for (final station in config.stations) {
    if (!selected.contains(station.id)) continue;
    final categoryIds = config.categoryIdsForStation(station.id);
    final stationItems = items
        .where((item) => categoryIds.contains(item.menuItem?.categoryId))
        .toList();
    if (stationItems.isNotEmpty) {
      batches.add((station: station, items: stationItems));
    }
  }
  return batches;
}

typedef KitchenTicketBatch = ({String targetName, List<OrderItem> items});

/// Item yang sama sekali belum masuk batch printer mana pun. Ini adalah pagar
/// terakhir agar kategori baru/salah mapping tetap sampai ke dapur.
@visibleForTesting
List<OrderItem> unroutedKitchenItems(
  List<OrderItem> items,
  Set<String> routedItemIds,
) => items.where((item) => !routedItemIds.contains(item.id)).toList();

/// Susun tiket akhir untuk satu printer dapur.
///
/// Mode `pisah` selalu menjadi prioritas: konfigurasi station hanya menyaring
/// kategori yang menjadi tanggung jawab printer, lalu setiap kategori tetap
/// dibuatkan tiket sendiri. Pada mode `gabung`, station hanya menyaring item
/// yang menjadi tanggung jawab printer; seluruh item itu dicetak dalam tepat
/// satu tiket agar label station/kategori tidak memecah satu order.
@visibleForTesting
List<KitchenTicketBatch> kitchenTicketBatchesForPrinter({
  required SavedPrinter printer,
  required List<OrderItem> items,
  required Map<String, String> categoryNames,
  PrintStationConfig? stationConfig,
}) {
  final mine = kitchenItemsForPrinterWithStations(
    printer,
    items,
    stationConfig: stationConfig,
  );
  if (mine.isEmpty) return const <KitchenTicketBatch>[];

  final baseName = printer.headerLabel.trim().isNotEmpty
      ? printer.headerLabel.trim()
      : (printer.name.isEmpty ? 'DAPUR' : printer.name);

  if (printer.printMode == 'pisah') {
    final byCategory = <String?, List<OrderItem>>{};
    for (final item in mine) {
      byCategory
          .putIfAbsent(item.menuItem?.categoryId, () => <OrderItem>[])
          .add(item);
    }
    return [
      for (final entry in byCategory.entries)
        (
          targetName: categoryNames[entry.key]?.trim().isNotEmpty == true
              ? categoryNames[entry.key]!.trim()
              : baseName,
          items: entry.value,
        ),
    ];
  }

  return [(targetName: baseName, items: mine)];
}

/// Cetak ulang ke printer yang dipilih tetap mengikuti mode kategori printer.
/// Pemilihan satu printer mencegah reprint tersebar ke perangkat lain.
@visibleForTesting
List<KitchenTicketBatch> manualKitchenReprintBatch({
  required SavedPrinter printer,
  required List<OrderItem> items,
  Map<String, String> categoryNames = const {},
  PrintStationConfig? stationConfig,
}) {
  return kitchenTicketBatchesForPrinter(
    printer: printer,
    items: items,
    categoryNames: categoryNames,
    stationConfig: stationConfig,
  );
}

/// Cetak daftar item ke semua printer dapur yang cocok dengan [trigger].
/// Menghormati mode pisah/gabung & jumlah salinan tiap printer.
Future<KitchenPrintResult> _printItemsToKitchen({
  required Order order,
  required List<OrderItem> items,
  required Map<String, String> categoryNames,
  KitchenTrigger? trigger,
  String titleSuffix = '',
  String? printedBy,
  DateTime? printedAt,
  String? claimedOrderId,
  String? claimedDeviceId,
  String? targetPrinterId,
  String? requestId,
  String? printIntent,
}) async {
  if (items.isEmpty) {
    return KitchenPrintResult(
      skippedReason: 'Pesanan tidak memiliki item untuk dicetak',
    );
  }
  final ps = PrinterService();
  final effectiveIntent =
      printIntent ??
      (targetPrinterId == null ? 'kitchen_initial' : 'kitchen_reprint');
  final effectiveRequestId =
      requestId ?? PrinterService.newPrintRequestId(effectiveIntent, order.id);
  final configuredPrinters = await ps.kitchenPrinters();
  final kitchenPrinters = kitchenPrintersForIntent(
    configuredPrinters,
    trigger: trigger,
    targetPrinterId: targetPrinterId,
  );
  final stationConfig = await _loadStationConfig(order.outletId);
  if (kitchenPrinters.isEmpty) {
    // Outlet tanpa printer dapur adalah konfigurasi yang sah. Jangan memenuhi
    // error_logs setiap ada order baru.
    debugPrint(
      'KitchenPrint: dilewati karena printer Dapur belum dikonfigurasi',
    );
    return KitchenPrintResult(
      skippedReason: targetPrinterId == null
          ? 'Belum ada printer Dapur yang aktif'
          : 'Printer Dapur yang dipilih tidak tersedia',
    );
  }
  var matched = false;
  var printed = 0;
  var queued = 0;
  var failedManual = 0;
  SavedPrinter? fallbackPrinter;
  final routedItemIds = <String>{};

  Future<void> sendTicket(
    SavedPrinter printer,
    String targetName,
    List<OrderItem> targetItems,
  ) async {
    if (claimedOrderId != null && claimedDeviceId != null) {
      final renewed = await renewKitchenPrintClaim(
        claimedOrderId,
        deviceId: claimedDeviceId,
      );
      if (!renewed) {
        throw StateError('Klaim tiket dapur tidak lagi dimiliki perangkat ini');
      }
    }
    final paper = printer.paper == '80' ? PaperSize.mm80 : PaperSize.mm58;
    final builder = KitchenTicketBuilder(
      paperSize: paper,
      driver: printer.driver,
    );
    final bytes = trigger == KitchenTrigger.voidOrder
        ? await builder.buildVoid(
            order: order,
            stationName: targetName,
            items: targetItems,
            printedAt: printedAt ?? DateTime.now(),
            printedBy: printedBy,
          )
        : await builder.build(
            order: order,
            stationName: '$targetName$titleSuffix',
            items: targetItems,
            printedAt: printedAt ?? DateTime.now(),
            printedBy: printedBy,
          );
    final sent = await ps.printToPrinterId(
      printer.id,
      bytes,
      kitchenOrderId: claimedOrderId,
      kitchenDeviceId: claimedDeviceId,
      copiesOverride: targetPrinterId == null ? null : 1,
      enqueueOnFailure: targetPrinterId == null,
      requestId: effectiveRequestId,
      intent: effectiveIntent,
    );
    debugPrint(
      'PrinterJob request=$effectiveRequestId intent=$effectiveIntent '
      'order=${order.id} receipt=kitchen target=${printer.id} '
      'section=$targetName items=${targetItems.length} success=$sent',
    );
    if (!sent) {
      if (targetPrinterId == null) {
        queued++;
        debugPrint(
          'KitchenPrint: tiket untuk ${printer.name} masuk antrean retry',
        );
      } else {
        failedManual++;
        debugPrint(
          'KitchenPrint: reprint manual untuk ${printer.name} gagal; '
          'tidak dimasukkan antrean retry',
        );
      }
    } else {
      printed++;
    }
  }

  for (final printer in kitchenPrinters) {
    fallbackPrinter ??= printer;
    final batches = targetPrinterId == null
        ? kitchenTicketBatchesForPrinter(
            printer: printer,
            items: items,
            categoryNames: categoryNames,
            stationConfig: stationConfig,
          )
        : manualKitchenReprintBatch(
            printer: printer,
            items: items,
            categoryNames: categoryNames,
            stationConfig: stationConfig,
          );
    if (batches.isEmpty) continue;
    matched = true;

    // Seluruh batch dikirim berurutan ke printer fisik yang sama. Pada mode
    // Pisah, nama batch adalah kategori; pada mode Gabung dapat berupa station.
    for (final batch in batches) {
      routedItemIds.addAll(batch.items.map((item) => item.id));
      await sendTicket(printer, batch.targetName, batch.items);
    }
  }

  // Salah konfigurasi kategori/station tidak boleh membuat makanan hilang dari
  // dapur. Item yang tidak masuk ke printer mana pun dicetak sekali ke printer
  // dapur pertama yang aktif, dengan judul yang jelas agar mapping bisa dibenahi.
  final unrouted = unroutedKitchenItems(items, routedItemIds)
      .where(
        (item) =>
            stationConfig == null ||
            !stationConfig.excludedCategoryIds.contains(
              item.menuItem?.categoryId,
            ),
      )
      .toList();
  if (targetPrinterId == null &&
      fallbackPrinter != null &&
      unrouted.isNotEmpty) {
    if (stationConfig != null) {
      final kitchenStationIds = stationConfig.stations
          .where((station) {
            final name = station.name.toLowerCase();
            return name.contains('dapur') || name.contains('kitchen');
          })
          .map((station) => station.id)
          .toSet();
      fallbackPrinter = kitchenPrinters.cast<SavedPrinter?>().firstWhere(
        (printer) =>
            printer != null &&
            kitchenPrinterMatches(printer, trigger) &&
            printer.effectiveStationIds.any(kitchenStationIds.contains),
        orElse: () => fallbackPrinter,
      );
    }
    matched = true;
    await sendTicket(fallbackPrinter!, 'DAPUR - BELUM DIPETAKAN', unrouted);
  }
  if (!matched) {
    final allExplicitlyExcluded =
        stationConfig != null &&
        items.every(
          (item) => stationConfig.excludedCategoryIds.contains(
            item.menuItem?.categoryId,
          ),
        );
    if (allExplicitlyExcluded) {
      return const KitchenPrintResult(
        skippedReason: 'Semua kategori sengaja tidak dicetak',
      );
    }
    // Toggle autoprint mati atau kategori tidak cocok adalah keputusan
    // konfigurasi, bukan kegagalan runtime.
    debugPrint(
      'KitchenPrint: dilewati karena autoprint mati atau kategori tidak cocok',
    );
    return const KitchenPrintResult(
      skippedReason:
          'Cetak otomatis mati atau kategori belum sesuai dengan printer',
    );
  }
  return KitchenPrintResult(
    printed: printed,
    queued: queued,
    skippedReason: failedManual > 0 && printed == 0
        ? 'Tiket gagal dikirim ke printer yang dipilih'
        : null,
  );
}

/// Ambil nama kategori (id -> name) untuk outlet (untuk judul tiket mode pisah).
Future<Map<String, String>> _categoryNames(String outletId) async {
  final datasource = PosDatasource();
  final cached = datasource.cachedCategoryNames(
    outletId,
    maxAge: PosDatasource.printCacheTtl,
  );
  if (cached.isNotEmpty) return cached;
  try {
    return await datasource.fetchCategoryNames(outletId);
  } catch (_) {
    return {};
  }
}

Future<PrintStationConfig?> _loadStationConfig(String outletId) async {
  if (outletId.isEmpty) return null;
  final datasource = PosDatasource();
  final cached = datasource.cachedOutletSettings(
    outletId,
    maxAge: PosDatasource.printCacheTtl,
  );
  if (cached != null) {
    final config = PrintStationConfig.fromSettings(cached);
    return config.isEnabled ? config : null;
  }
  try {
    // Datasource memperbarui timestamp cache saat online dan otomatis memakai
    // cache lama sebagai fallback ketika perangkat sedang offline.
    final settings = await datasource.fetchOutletSettings(outletId);
    final config = PrintStationConfig.fromSettings(settings);
    return config.isEnabled ? config : null;
  } catch (_) {
    // Printer tetap dapat memakai mapping kategori lokal saat offline.
    return null;
  }
}

Future<Order?> _fetchOrder(String orderId) async {
  // Insert `orders` dan `order_items` dari web tidak selalu tiba bersamaan di
  // realtime. Retry singkat supaya autoprint order tidak hilang akibat race.
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      final data = await Supabase.instance.client
          .from('orders')
          .select(
            '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price))',
          )
          .eq('id', orderId)
          .single();
      final order = Order.fromJson(data);
      if (order.items != null && order.items!.isNotEmpty) return order;
    } catch (_) {
      // Coba lagi: transaksi web mungkin belum selesai terlihat oleh query ini.
    }
    if (attempt < 4) {
      await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }
  }
  return null;
}

/// Manual kitchen reprint may originate from a compact sales/history row that
/// intentionally has no `order_items`. Reuse an in-memory complete snapshot,
/// otherwise load the same order read-only before opening the item selector.
Future<Order?> orderForManualKitchenPrint(
  Order snapshot, {
  Future<Order?> Function(String orderId)? fetchOrder,
}) async {
  if (snapshot.items?.isNotEmpty == true) return snapshot;
  return (fetchOrder ?? _fetchOrder)(snapshot.id);
}

/// Cetak tiket dapur dari Order yang SUDAH ada di memori (mis. transaksi
/// offline) — tanpa fetch ke Supabase. Dipakai saat POS offline agar tiket
/// dapur tetap tercetak. [categoryNames] boleh kosong (judul mode pisah
/// fallback ke nama printer).
Future<KitchenPrintResult> printKitchenTicketsForLocalOrder({
  required Order order,
  Map<String, String> categoryNames = const {},
  KitchenTrigger? trigger = KitchenTrigger.bayar,
  String? printedBy,
  DateTime? printedAt,
}) async {
  final items = order.items;
  if (items == null || items.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Pesanan tidak memiliki item untuk dicetak',
    );
  }
  return _printItemsToKitchen(
    order: order,
    items: items,
    categoryNames: categoryNames,
    trigger: trigger,
    printedBy: printedBy,
    printedAt: printedAt,
  );
}

/// Cetak struk VOID hanya untuk item dan jumlah yang baru dibatalkan.
///
/// [order] menyimpan nomor nota dan jenis order. [items] adalah snapshot item
/// sebelum jumlahnya dikurangi atau barisnya dihapus dari database.
Future<KitchenPrintResult> printKitchenVoidTicketsForItems({
  required Order order,
  required List<OrderItem> items,
  String? printedBy,
  DateTime? printedAt,
}) async {
  if (items.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Tidak ada item void untuk dicetak',
    );
  }
  final names = await _categoryNames(order.outletId);
  return _printItemsToKitchen(
    order: order,
    items: items,
    categoryNames: names,
    trigger: KitchenTrigger.voidOrder,
    printedBy: printedBy,
    printedAt: printedAt,
  );
}

/// Cetak ulang tiket dapur hanya untuk item dan jumlah yang dipilih kasir.
///
/// Pemilihan printer dan pemisahan stasiun tetap mengikuti pengaturan dapur.
/// Trigger sengaja dibuat null karena tindakan ini adalah cetak manual.
Future<KitchenPrintResult> printKitchenTicketsForSelectedItems({
  required Order order,
  required List<OrderItem> items,
  required String targetPrinterId,
  String? printedBy,
  DateTime? printedAt,
}) async {
  if (items.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Pilih sedikitnya satu item untuk dicetak',
    );
  }
  final names = await _categoryNames(order.outletId);
  return _printItemsToKitchen(
    order: order,
    items: items,
    categoryNames: names,
    trigger: null,
    targetPrinterId: targetPrinterId,
    requestId: PrinterService.newPrintRequestId('kitchen_reprint', order.id),
    printIntent: 'kitchen_reprint',
    printedBy: printedBy,
    printedAt: printedAt,
  );
}

/// Cetak tiket dapur untuk SELURUH item order, ke printer dapur yang cocok
/// dengan [trigger]. [trigger] null = paksa cetak semua (reprint manual).
Future<KitchenPrintResult> printKitchenTicketsForOrder({
  required String orderId,
  required String outletId,
  KitchenTrigger? trigger,
  bool force = false,
  String? printedBy,
  DateTime? printedAt,
  bool skipIfAlreadyPrinted = false,
  bool claimBeforePrint = false,
}) async {
  if (outletId.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Cabang pesanan tidak ditemukan',
    );
  }
  final order = await _fetchOrder(orderId);
  if (order == null || order.items == null || order.items!.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Data pesanan belum tersedia untuk dicetak',
    );
  }
  if (skipIfAlreadyPrinted && order.kitchenPrinted) {
    return const KitchenPrintResult(
      skippedReason: 'Tiket dapur sudah pernah dicetak',
    );
  }
  var claimed = false;
  String? claimDeviceId;
  if (claimBeforePrint) {
    claimDeviceId = await PrinterService().devicePrintId();
    claimed = await claimKitchenPrint(orderId, deviceId: claimDeviceId);
    if (!claimed) {
      return const KitchenPrintResult(
        skippedReason: 'Tiket dapur sedang/sudah diproses perangkat lain',
      );
    }
  }
  final names = await _categoryNames(outletId);
  try {
    final result = await _printItemsToKitchen(
      order: order,
      items: order.items!,
      categoryNames: names,
      trigger: force ? null : trigger,
      printedBy: printedBy,
      printedAt: printedAt,
      claimedOrderId: claimed ? orderId : null,
      claimedDeviceId: claimed ? claimDeviceId : null,
    );
    if (claimed) {
      if (result.hasQueued) {
        await deferKitchenPrintClaim(orderId, deviceId: claimDeviceId);
      } else if (result.hasPrinted ||
          result.skippedReason == 'Semua kategori sengaja tidak dicetak') {
        var completed = false;
        try {
          completed = await completeKitchenPrintClaim(
            orderId,
            deviceId: claimDeviceId,
          );
        } catch (_) {
          // Kertas sudah keluar. Simpan hanya acknowledgement agar retry tidak
          // pernah mencetak byte tiket yang sama untuk kedua kalinya.
        }
        if (!completed) {
          try {
            await deferKitchenPrintClaim(orderId, deviceId: claimDeviceId);
          } catch (_) {
            // Server masih tidak terjangkau; acknowledgement persisten di
            // bawah akan mencoba menyelesaikan tanpa mencetak ulang.
          }
          await PrinterService().enqueueKitchenAcknowledgement(
            orderId: orderId,
            deviceId: claimDeviceId!,
          );
        }
      } else {
        await releaseKitchenPrintClaim(orderId, deviceId: claimDeviceId);
      }
    }
    return result;
  } catch (_) {
    if (claimed) {
      try {
        // Jangan bebaskan klaim setelah exception: batch sebelumnya mungkin
        // sudah keluar. Lease tertunda mencegah perangkat lain menduplikasi.
        await deferKitchenPrintClaim(orderId, deviceId: claimDeviceId);
      } catch (_) {}
    }
    rethrow;
  }
}

/// Cetak tiket dapur HANYA untuk item yang baru ditambahkan (open bill).
Future<KitchenPrintResult> printKitchenTicketsForNewItems({
  required String orderId,
  required String outletId,
  required List<OrderItem> items,
  String? printedBy,
  DateTime? printedAt,
}) async {
  if (outletId.isEmpty || items.isEmpty) {
    return const KitchenPrintResult(
      skippedReason: 'Tidak ada item tambahan untuk dicetak',
    );
  }
  final order = await _fetchOrder(orderId);
  if (order == null) {
    return const KitchenPrintResult(
      skippedReason: 'Data pesanan belum tersedia untuk dicetak',
    );
  }
  final names = await _categoryNames(outletId);
  return _printItemsToKitchen(
    order: order,
    items: items,
    categoryNames: names,
    trigger: KitchenTrigger.order, // item baru = autoOrder
    titleSuffix: ' (TAMBAHAN)',
    printedBy: printedBy,
    printedAt: printedAt,
  );
}

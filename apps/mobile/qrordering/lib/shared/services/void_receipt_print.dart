import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show PaperSize;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/order.dart';
import 'printer_service.dart';
import 'receipt_builder.dart';

/// Membuat dan mengirim struk pembatalan ke printer yang berperan sebagai
/// printer Struk. Struk Void tidak mengikuti batas cetak struk penjualan karena
/// merupakan dokumen audit yang berbeda.
Future<PrintOutcome> printVoidReceipt({
  required Order order,
  required String reason,
  String? approverName,
  List<OrderItem>? items,
}) async {
  final printer = PrinterService();
  final receiptPrinter = await printer.printerForReceipt();
  if (receiptPrinter == null) return PrintOutcome.skipped;

  final outletData = await Supabase.instance.client
      .from('outlets')
      .select('name, address, phone, city, settings')
      .eq('id', order.outletId)
      .single();

  final builder = ReceiptBuilder(
    outlet: OutletReceiptInfo.fromMap(outletData),
    paperSize: receiptPrinter.paper == '80' ? PaperSize.mm80 : PaperSize.mm58,
    driver: receiptPrinter.driver,
  );
  final notes = <String>[
    'Alasan: $reason',
    if (approverName != null && approverName.trim().isNotEmpty)
      'Disetujui: ${approverName.trim()}',
    'Waktu Void: ${DateFormat('dd/MM/yyyy HH:mm', 'id_ID').format(DateTime.now())}',
  ];
  final bytes = await builder.build(
    order: order,
    customerName: order.customerName,
    documentTitle: 'STRUK VOID',
    documentNotes: notes,
    documentItems: items,
    showFinancialSummary: false,
  );
  final outcome = await printer.printReceiptBytes(
    bytes,
    jobLabel: 'Struk Void ${order.orderNumber}',
    // VOID adalah aksi audit yang eksplisit. Jika koneksi gagal/ambigu, jangan
    // menyimpannya untuk keluar sendiri setelah restart atau reconnect.
    enqueueOnFailure: false,
    requestId: PrinterService.newPrintRequestId('void', order.id),
    intent: 'void',
  );
  debugPrint(
    'PrinterJob intent=VOID order=${order.id} receipt=cashier '
    'target=${receiptPrinter.id} items=${items?.length ?? order.items?.length ?? 0} '
    'outcome=${outcome.name}',
  );
  return outcome;
}

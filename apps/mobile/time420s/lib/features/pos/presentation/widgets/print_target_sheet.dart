import 'package:flutter/material.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/receipt_builder.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../data/datasources/pos_datasource.dart';
import '../../../orders/presentation/widgets/kitchen_item_print_dialog.dart';

typedef ReceiptTargetPrinter =
    Future<bool> Function(String orderId, String outletId, String? cashierName);
typedef KitchenTargetPrinter =
    Future<KitchenPrintResult> Function({
      required String orderId,
      required String outletId,
      bool force,
      String? printedBy,
    });
typedef ManualKitchenOrderLoader = Future<Order?> Function(Order snapshot);

/// Bottom sheet: pilih tujuan cetak (per stasiun) untuk sebuah order —
/// Struk Kasir (struk pelanggan) &/atau Tiket Dapur.
Future<void> showPrintTargetSheet(
  BuildContext context, {
  required String orderId,
  required String outletId,
  String? cashierName,
  Order? orderSnapshot,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _PrintTargetSheet(
      orderId: orderId,
      outletId: outletId,
      cashierName: cashierName,
      orderSnapshot: orderSnapshot,
    ),
  );
}

@visibleForTesting
Widget printTargetSheetForTesting({
  required String orderId,
  required String outletId,
  String? cashierName,
  required ReceiptTargetPrinter printReceipt,
  KitchenTargetPrinter? printKitchen,
  Order? orderSnapshot,
  ManualKitchenOrderLoader? loadManualKitchenOrder,
  KitchenItemsPrinter? printSelectedItems,
  List<SavedPrinter>? initialKitchenPrinters,
}) {
  return _PrintTargetSheet(
    orderId: orderId,
    outletId: outletId,
    cashierName: cashierName,
    orderSnapshot: orderSnapshot,
    printReceipt: printReceipt,
    printKitchen: printKitchen,
    loadManualKitchenOrder: loadManualKitchenOrder,
    printSelectedItems: printSelectedItems,
    initialKitchenPrinters: initialKitchenPrinters,
  );
}

class _PrintTargetSheet extends StatefulWidget {
  final String orderId;
  final String outletId;
  final String? cashierName;
  final Order? orderSnapshot;
  final ReceiptTargetPrinter? printReceipt;
  final KitchenTargetPrinter? printKitchen;
  final ManualKitchenOrderLoader? loadManualKitchenOrder;
  final KitchenItemsPrinter? printSelectedItems;
  final List<SavedPrinter>? initialKitchenPrinters;
  const _PrintTargetSheet({
    required this.orderId,
    required this.outletId,
    this.cashierName,
    this.orderSnapshot,
    this.printReceipt,
    this.printKitchen,
    this.loadManualKitchenOrder,
    this.printSelectedItems,
    this.initialKitchenPrinters,
  });

  @override
  State<_PrintTargetSheet> createState() => _PrintTargetSheetState();
}

class _PrintTargetSheetState extends State<_PrintTargetSheet> {
  String? _busy; // 'kasir' | 'dapur' saat sedang mencetak

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: error
            ? const Color(0xFF991B1B)
            : const Color(0xFF111111),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _printKasir() async {
    setState(() => _busy = 'kasir');
    final ok = widget.printReceipt != null
        ? await widget.printReceipt!(
            widget.orderId,
            widget.outletId,
            widget.cashierName,
          )
        : await _printReceiptToKasir(
            widget.orderId,
            widget.outletId,
            widget.cashierName,
            orderSnapshot: widget.orderSnapshot,
          );
    if (!mounted) return;
    setState(() => _busy = null);
    _snack(ok ? 'Struk kasir tercetak' : 'Gagal cetak struk kasir', error: !ok);
  }

  Future<void> _printDapur() async {
    setState(() => _busy = 'dapur');
    try {
      KitchenPrintResult? result;
      if (widget.printKitchen != null) {
        result = await widget.printKitchen!(
          orderId: widget.orderId,
          outletId: widget.outletId,
          force: true,
          printedBy: widget.cashierName,
        );
      } else if (widget.orderSnapshot != null) {
        final snapshot = widget.orderSnapshot!;
        final order =
            await (widget.loadManualKitchenOrder?.call(snapshot) ??
                orderForManualKitchenPrint(snapshot));
        if (!mounted) return;
        setState(() => _busy = null);
        if (order == null || order.items?.isNotEmpty != true) {
          _snack(
            'Detail item pesanan belum tersedia. Muat ulang transaksi lalu coba lagi.',
            error: true,
          );
          return;
        }
        result = await showKitchenItemPrintDialog(
          context,
          order: order,
          printedBy: widget.cashierName,
          printItems: widget.printSelectedItems,
          initialPrinters: widget.initialKitchenPrinters,
        );
        if (result == null) return;
      } else {
        result = await printKitchenTicketsForOrder(
          orderId: widget.orderId,
          outletId: widget.outletId,
          force: true,
          printedBy: widget.cashierName,
        );
      }
      if (!mounted) return;
      setState(() => _busy = null);
      if (result.hasPrinted) {
        final queueInfo = result.hasQueued
            ? ' ${result.queued} tiket lain masuk antrean.'
            : '';
        _snack('${result.printed} tiket dapur tercetak.$queueInfo');
      } else if (result.hasQueued) {
        _snack('${result.queued} tiket dapur masuk antrean cetak.');
      } else {
        _snack(
          result.skippedReason ?? 'Tidak ada tiket dapur yang dapat dicetak.',
          error: true,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = null);
      _snack(
        'Gagal menyiapkan tiket dapur. Periksa printer lalu coba lagi.',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Cetak Struk',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Pilih tujuan cetak',
              style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 14),
            _TargetRow(
              iconBg: const Color(0xFFFFECEC),
              iconColor: const Color(0xFFB03030),
              icon: Icons.receipt_long_outlined,
              title: 'Struk Kasir',
              subtitle: 'Struk pelanggan',
              busy: _busy == 'kasir',
              enabled: _busy == null,
              onTap: _printKasir,
            ),
            const SizedBox(height: 8),
            _TargetRow(
              iconBg: const Color(0xFFEAF3DE),
              iconColor: const Color(0xFF27500A),
              icon: Icons.soup_kitchen_outlined,
              title: 'Tiket Dapur',
              subtitle: 'Cetak ke printer dapur',
              busy: _busy == 'dapur',
              enabled: _busy == null,
              onTap: _printDapur,
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: _busy == null ? () => Navigator.pop(context) : null,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE24B4A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  'Selesai',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  final Color iconBg;
  final Color iconColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  const _TargetRow({
    required this.iconBg,
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled || busy ? 1 : 0.5,
      child: Material(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF111111),
                        ),
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ),
                ),
                busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFE24B4A),
                        ),
                      )
                    : const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Color(0xFFD0D0D0),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cetak struk pelanggan ke printer kasir. Best-effort (Android + printer).
Future<bool> _printReceiptToKasir(
  String orderId,
  String outletId,
  String? cashierName, {
  Order? orderSnapshot,
}) async {
  if (!PrinterService.isSupported || orderId.isEmpty || outletId.isEmpty) {
    return false;
  }
  try {
    final printer = PrinterService();
    // Printer LAN mencetak lewat socket — isConnected selamanya false untuknya.
    // Tanpa penjagaan ini, setup LAN gagal cetak di sini tanpa pesan apa pun.
    if (await printer.receiptNeedsBluetoothConnect() && !printer.isConnected) {
      final ok = await printer.tryAutoReconnect();
      if (!ok) return false;
    }
    var order = orderSnapshot;
    if (ConnectivityService.instance.online.value) {
      try {
        final orderData = await Supabase.instance.client
            .from('orders')
            .select(
              '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price)), payments(method, amount)',
            )
            .eq('id', orderId)
            .single();
        order = Order.fromJson(orderData);
      } catch (_) {
        // Reprint tetap dapat memakai snapshot daftar order.
      }
    }
    if (order == null) return false;

    final datasource = PosDatasource();
    Map<String, dynamic>? outletData = datasource.cachedOutletReceiptMap(
      outletId,
    );
    if (ConnectivityService.instance.online.value) {
      outletData = await datasource.fetchOutletReceiptMap(outletId);
    }
    if (outletData == null) return false;
    final info = OutletReceiptInfo.fromMap(outletData);

    // Order yang sudah dibayar (mis. reprint dari detail order) → sertakan
    // baris metode bayar & kembalian, bukan cuma order kosongan.
    final paymentBreakdown = receiptPaymentBreakdown(
      order.payments ?? const [],
    );

    final rcpt = await printer.printerForReceipt();
    final paper = rcpt?.paper == '80' ? PaperSize.mm80 : PaperSize.mm58;
    final builder = ReceiptBuilder(
      outlet: info,
      paperSize: paper,
      driver: rcpt?.driver ?? 'generic1',
    );
    final bytes = await builder.build(
      order: order,
      paymentBreakdown: paymentBreakdown,
      cashierName: cashierName,
      customerName: order.customerName,
      waiterName: cashierName,
    );
    // Cetak manual → tanpa `auto:`, jadi tak terpengaruh toggle Autoprint Bayar.
    return (await printer.printReceiptBytes(bytes)).isPrinted;
  } catch (_) {
    return false;
  }
}

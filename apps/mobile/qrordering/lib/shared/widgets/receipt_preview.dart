import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/order.dart';
import '../models/menu_item.dart';
import '../models/enums.dart';
import '../services/receipt_builder.dart' show OutletReceiptInfo, ReceiptConfig;

/// Pratinjau struk ON-SCREEN (widget, bukan cetak). Mencerminkan
/// [ReceiptBuilder.build] SATU-PER-SATU agar tampilan preview = hasil cetak.
///
/// Dipakai di dua tempat: Pengaturan Struk (dengan order contoh + setelan hidup)
/// dan pratinjau order nyata (tombol "Lihat Struk").
///
/// Bila [ReceiptBuilder.build] berubah, sesuaikan widget ini juga — keduanya
/// sengaja bergantung pada model yang sama (OutletReceiptInfo/ReceiptConfig).
class ReceiptPreview extends StatelessWidget {
  final OutletReceiptInfo outlet;
  final Order order;
  final PaymentMethod? paymentMethod;
  final double? cashReceived;
  final Map<PaymentMethod, double> paymentBreakdown;
  final String? cashierName;
  final String? customerName;
  final String? waiterName;

  const ReceiptPreview({
    super.key,
    required this.outlet,
    required this.order,
    this.paymentMethod,
    this.cashReceived,
    this.paymentBreakdown = const {},
    this.cashierName,
    this.customerName,
    this.waiterName,
  });

  static final _money = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp',
    decimalDigits: 0,
  );
  static String _m(double v) => _money.format(v);
  static String _pct(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  static const _paymentLabels = {
    PaymentMethod.cash: 'Tunai',
    PaymentMethod.qris: 'QRIS',
    PaymentMethod.debit: 'Debit',
    PaymentMethod.credit: 'Kredit',
    PaymentMethod.ewallet: 'E-Wallet',
    PaymentMethod.transfer: 'Transfer',
  };

  // Gaya monospace ala kertas thermal.
  static const _mono = 'monospace';
  static const _ink = Color(0xFF1A1A1A);

  TextStyle get _base => const TextStyle(
    fontFamily: _mono,
    fontSize: 11,
    color: _ink,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    final cfg = outlet.receipt;
    final paidFromBreakdown = paymentBreakdown.values.fold<double>(
      0,
      (sum, amount) => sum + amount,
    );
    final receiptIsFullyPaid =
        order.isFullyPaid || paidFromBreakdown >= order.totalAmount - 0.01;
    final rows = <Widget>[];

    // ── HEADER ────────────────────────────────────────────────────────────
    if (cfg.showLogo) rows.add(_logo(cfg));
    if (cfg.showOutletName || cfg.showBusinessName) {
      rows.add(_center(outlet.name, bold: true, size: 15));
    }
    if (cfg.showAddress && outlet.address.isNotEmpty) {
      rows.add(_center(outlet.address));
    }
    if (cfg.showPhone && outlet.phone.isNotEmpty) {
      rows.add(_center('Telp: ${outlet.phone}'));
    }
    if (cfg.showCity && outlet.city.isNotEmpty) {
      rows.add(_center(outlet.city));
    }
    if (cfg.showProvince && outlet.province.isNotEmpty) {
      rows.add(_center(outlet.province));
    }
    if (cfg.showCountry && outlet.country.isNotEmpty) {
      rows.add(_center(outlet.country));
    }
    for (final f in cfg.customHeaderFields) {
      if (!f.visible || f.label.isEmpty) continue;
      rows.add(_center(f.value.isEmpty ? f.label : '${f.label}: ${f.value}'));
    }
    if (cfg.customHeader && cfg.customHeaderText.isNotEmpty) {
      rows.add(_aligned(cfg.customHeaderText, cfg.customHeaderAlign));
    }
    rows.add(_hr());

    if (order.orderType == OrderType.selfOrder && !receiptIsFullyPaid) {
      rows.add(_center('ORDER QR - BELUM DIBAYAR', bold: true, size: 14));
      rows.add(_hr());
    }

    // ── BODY (metadata) ───────────────────────────────────────────────────
    if (cfg.showOrderNumber) {
      rows.add(_kv('No Nota', order.orderNumber, bold: true));
    }
    if (cfg.showOrderTime) {
      rows.add(
        _kv(
          'Waktu',
          DateFormat(
            'dd/MM/yyyy HH:mm',
            'id_ID',
          ).format(order.createdAt.toLocal()),
        ),
      );
    }
    if (cfg.showCashierOrder &&
        order.orderType != OrderType.selfOrder &&
        (cashierName?.isNotEmpty ?? false)) {
      rows.add(_kv('Kasir Order', cashierName!));
    }
    if (cfg.showCashierPay && (cashierName?.isNotEmpty ?? false)) {
      rows.add(_kv('Kasir Bayar', cashierName!));
    }
    if (cfg.showCustomer && (customerName?.isNotEmpty ?? false)) {
      rows.add(_kv('Customer', customerName!));
    }
    if (cfg.showWaiter &&
        (waiterName?.isNotEmpty ?? false) &&
        !(order.orderType == OrderType.selfOrder &&
            waiterName!.trim() == cashierName?.trim())) {
      rows.add(_kv('Dilayani', waiterName!));
    }
    if (cfg.showOrderType) {
      rows.add(_kv('Jenis Order', order.operationalOrderTypeLabel));
    }
    if (cfg.showOrderName &&
        (order.customerName?.isNotEmpty ?? false) &&
        order.customerName!.trim() != customerName?.trim()) {
      rows.add(_kv('Nama Order', order.customerName!));
    }
    if (cfg.showTable && order.shouldDisplayTable) {
      rows.add(_kv('Nomor Meja', order.tableNumber!));
    }
    for (final f in cfg.customBodyFields) {
      if (!f.visible || f.label.isEmpty) continue;
      rows.add(_kv(f.label, f.value));
    }
    if (order.customerOrderNote != null) {
      rows.add(_small('Catatan Order: ${order.customerOrderNote}'));
    }
    rows.add(_hr());

    // ── ITEMS ─────────────────────────────────────────────────────────────
    final items = order.items ?? const [];
    if (items.isNotEmpty) {
      for (final item in items) {
        final name = item.menuItem?.name ?? 'Item';
        final label = item.quantity > 1 ? '$name x${item.quantity}' : name;
        rows.add(_itemRow(label, _m(item.subtotal)));
        for (final opt in item.options) {
          rows.add(
            _small(
              opt.price > 0
                  ? '  + ${opt.optionName} (+${_m(opt.price)})'
                  : '  + ${opt.optionName}',
            ),
          );
        }
        if (item.notes?.isNotEmpty ?? false) {
          rows.add(_small('  Catatan: ${item.notes}'));
        }
      }
      rows.add(_hr());
    }

    // ── TOTALS ────────────────────────────────────────────────────────────
    rows.add(_kv('Subtotal', _m(order.subtotal)));
    if (order.discountAmount > 0) {
      rows.add(_kv('Diskon', '-${_m(order.discountAmount)}'));
    }
    if (order.serviceCharge > 0) {
      final p = outlet.serviceChargePercent > 0
          ? ' ${_pct(outlet.serviceChargePercent)}%'
          : '';
      rows.add(_kv('Service$p', _m(order.serviceCharge)));
    }
    if (order.taxAmount > 0 && !outlet.taxInclusive) {
      final p = outlet.taxPercent > 0 ? ' ${_pct(outlet.taxPercent)}%' : '';
      rows.add(_kv('${outlet.taxName}$p', _m(order.taxAmount)));
    }
    rows.add(_hr());
    rows.add(_totalRow(_m(order.totalAmount)));
    rows.add(_hr());

    // ── PAYMENT ───────────────────────────────────────────────────────────
    if (paymentBreakdown.isNotEmpty) {
      for (final entry in paymentBreakdown.entries) {
        rows.add(
          _kv(_paymentLabels[entry.key] ?? entry.key.value, _m(entry.value)),
        );
      }
    } else if (paymentMethod != null) {
      rows.add(
        _kv(
          _paymentLabels[paymentMethod] ?? paymentMethod!.value,
          _m(cashReceived ?? order.totalAmount),
        ),
      );
      if (paymentMethod == PaymentMethod.cash && cashReceived != null) {
        final change = cashReceived! - order.totalAmount;
        if (change > 0) {
          rows.add(_kv('Kembali', _m(change)));
        }
      }
    }

    // ── Tax inclusive notice ──────────────────────────────────────────────
    if (outlet.taxInclusive && order.taxAmount > 0) {
      rows.add(_hr());
      rows.add(_center('Harga Sudah Termasuk ${outlet.taxName}'));
      rows.add(_center('Senilai ${_m(order.taxAmount)}'));
    }

    // ── FOOTER ────────────────────────────────────────────────────────────
    if (cfg.footer.isNotEmpty) {
      rows.add(_hr());
      for (final line in cfg.footer.split('\n')) {
        rows.add(_center(line));
      }
    }

    return Container(
      width: 300,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  // ── Bagian-bagian ───────────────────────────────────────────────────────
  Widget _logo(ReceiptConfig cfg) {
    final url = cfg.logoUrl;
    final size = cfg.logoStyle == 'full' ? 130.0 : 80.0;
    final img = (url != null && url.trim().isNotEmpty)
        ? Image.network(
            url.trim(),
            width: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _assetLogo(size),
          )
        : _assetLogo(size);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // Grayscale supaya realistis dgn cetak thermal.
      child: Center(
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: img,
        ),
      ),
    );
  }

  Widget _assetLogo(double size) => Image.asset(
    'assets/images/logo.png',
    width: size,
    fit: BoxFit.contain,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );

  Widget _center(String text, {bool bold = false, double? size}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: _base.copyWith(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontSize: size,
      ),
    ),
  );

  Widget _aligned(String text, String align) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Text(
      text,
      textAlign: align == 'left'
          ? TextAlign.left
          : align == 'right'
          ? TextAlign.right
          : TextAlign.center,
      style: _base,
    ),
  );

  Widget _kv(String k, String v, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(k, style: _base)),
        const SizedBox(width: 6),
        Text(
          v,
          style: _base.copyWith(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    ),
  );

  Widget _itemRow(String label, String price) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: _base)),
        const SizedBox(width: 6),
        Text(price, style: _base),
      ],
    ),
  );

  Widget _small(String text) => Text(
    text,
    style: _base.copyWith(fontSize: 9, color: const Color(0xFF555555)),
  );

  Widget _totalRow(String total) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'TOTAL',
            style: _base.copyWith(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
        Text(
          total,
          style: _base.copyWith(fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ],
    ),
  );

  Widget _hr() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: _DashedLine(),
  );
}

/// Garis putus-putus (pengganti `g.hr()` thermal).
class _DashedLine extends StatelessWidget {
  const _DashedLine();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 1,
    width: double.infinity,
    child: CustomPaint(painter: _DashPainter()),
  );
}

class _DashPainter extends CustomPainter {
  const _DashPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFBBBBBB)
      ..strokeWidth = 1;
    const dash = 3.0, gap = 3.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dash, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Tampilkan [ReceiptPreview] dalam modal bottom sheet (di atas latar gelap,
/// seperti struk di atas meja). Dipakai dari Pengaturan Struk & Daftar Order.
Future<void> showReceiptPreviewSheet(
  BuildContext context, {
  required OutletReceiptInfo outlet,
  required Order order,
  PaymentMethod? paymentMethod,
  double? cashReceived,
  Map<PaymentMethod, double> paymentBreakdown = const {},
  String? cashierName,
  String? customerName,
  String? waiterName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFECECEC),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFC4C4C4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Pratinjau Struk',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111111),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                child: Center(
                  child: ReceiptPreview(
                    outlet: outlet,
                    order: order,
                    paymentMethod: paymentMethod,
                    cashReceived: cashReceived,
                    paymentBreakdown: paymentBreakdown,
                    cashierName: cashierName,
                    customerName: customerName,
                    waiterName: waiterName,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Order CONTOH untuk pratinjau di Pengaturan Struk (bukan data nyata).
Order sampleReceiptOrder() {
  MenuItem mi(String id, String name, double price) => MenuItem(
    id: id,
    outletId: 'preview',
    name: name,
    price: price,
    isAvailable: true,
    isActive: true,
    isFeatured: false,
    sortOrder: 0,
  );
  return Order(
    id: 'preview',
    outletId: 'preview',
    orderNumber: 'A-001',
    orderType: OrderType.dineIn,
    status: OrderStatus.paid,
    customerName: 'Budi',
    subtotal: 75000,
    discountAmount: 5000,
    taxAmount: 7000,
    serviceCharge: 3500,
    totalAmount: 80500,
    stockDeducted: true,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    tableNumber: '5',
    items: [
      OrderItem(
        id: '1',
        orderId: 'preview',
        menuItemId: 'm1',
        menuItem: mi('m1', 'Kopi Susu', 25000),
        quantity: 2,
        unitPrice: 25000,
        subtotal: 50000,
        options: const [
          OrderItemOption(
            extraName: 'Topping',
            optionName: 'Extra Shot',
            price: 5000,
          ),
        ],
      ),
      OrderItem(
        id: '2',
        orderId: 'preview',
        menuItemId: 'm2',
        menuItem: mi('m2', 'Roti Bakar', 25000),
        quantity: 1,
        unitPrice: 25000,
        subtotal: 25000,
        notes: 'Tanpa selai',
      ),
    ],
  );
}

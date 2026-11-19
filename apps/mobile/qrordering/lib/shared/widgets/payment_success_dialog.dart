import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/utils/currency_formatter.dart';
import '../models/enums.dart';

const _typeLabels = {
  OrderType.dineIn: 'Dine In',
  OrderType.takeaway: 'Takeaway',
  OrderType.selfOrder: 'Order Online',
};

/// Popup pembayaran berhasil bergaya struk. Backdrop tidak menutup modal —
/// user harus menekan "Selesai".
Future<void> showPaymentSuccess(
  BuildContext context, {
  required String orderNumber,
  String? customerName,
  required OrderType orderType,
  required double subtotal,
  required double tax,
  required double service,
  required double total,
  double kembalian = 0,
  bool offline = false,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => _PaymentSuccessDialog(
      orderNumber: orderNumber,
      customerName: customerName,
      orderType: orderType,
      subtotal: subtotal,
      tax: tax,
      service: service,
      total: total,
      kembalian: kembalian,
      offline: offline,
    ),
  );
}

/// Permukaan uji tanpa membuka route dialog.
@visibleForTesting
Widget paymentSuccessDialogForTesting({
  required String orderNumber,
  String? customerName,
  required OrderType orderType,
  required double subtotal,
  required double tax,
  required double service,
  required double total,
  double kembalian = 0,
  bool offline = false,
}) {
  return _PaymentSuccessDialog(
    orderNumber: orderNumber,
    customerName: customerName,
    orderType: orderType,
    subtotal: subtotal,
    tax: tax,
    service: service,
    total: total,
    kembalian: kembalian,
    offline: offline,
  );
}

class _PaymentSuccessDialog extends StatelessWidget {
  final String orderNumber;
  final String? customerName;
  final OrderType orderType;
  final double subtotal;
  final double tax;
  final double service;
  final double total;
  final double kembalian;
  final bool offline;

  const _PaymentSuccessDialog({
    required this.orderNumber,
    required this.customerName,
    required this.orderType,
    required this.subtotal,
    required this.tax,
    required this.service,
    required this.total,
    required this.kembalian,
    required this.offline,
  });

  @override
  Widget build(BuildContext context) {
    final taxPct = subtotal > 0 ? (tax / subtotal * 100).round() : 0;
    final svcPct = subtotal > 0 ? (service / subtotal * 100).round() : 0;
    final name = (customerName?.trim().isNotEmpty ?? false)
        ? customerName!.trim()
        : 'Tanpa Pelanggan';
    final typeLabel = _typeLabels[orderType] ?? '-';
    final sub = orderNumber.isEmpty
        ? '$name · $typeLabel'
        : 'Order #$orderNumber · $name · $typeLabel';
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final width = math.min(380.0, math.max(0.0, sw - 32));
    final height = math.max(0.0, sh - 32);

    final modal = Center(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── 1. Icon + judul ─────────────────────────────────
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: offline
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF0F766E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    offline ? Icons.cloud_off : Icons.check_rounded,
                    size: 24,
                    color: Colors.white,
                  ),
                ),
                Text(
                  offline ? 'Tersimpan (Offline)' : 'Pembayaran Berhasil',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF999999),
                  ),
                ),
                const SizedBox(height: 16),

                // ── 2. Receipt card ─────────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE0E0E0)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      _row('Subtotal', CurrencyFormatter.format(subtotal)),
                      if (tax > 0)
                        _row('Pajak ($taxPct%)', CurrencyFormatter.format(tax)),
                      if (service > 0)
                        _row(
                          'Biaya Layanan ($svcPct%)',
                          CurrencyFormatter.format(service),
                        ),
                      const _ReceiptDivider(),
                      _amountRow(
                        'Total',
                        CurrencyFormatter.format(total),
                        bold: true,
                      ),
                      if (kembalian > 0) ...[
                        const _ReceiptDivider(),
                        _amountRow(
                          'Kembalian',
                          CurrencyFormatter.format(kembalian),
                          valueColor: const Color(0xFF1D9E75),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ── 3. Info status ──────────────────────────────────
                Text(
                  offline
                      ? '⏳ Akan tersinkron saat online'
                      : '✅ Transaksi selesai',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFBBBBBB),
                  ),
                ),
                const SizedBox(height: 14),

                // ── 4. Tombol Selesai ───────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: Material(
                    color: const Color(0xFF0F766E),
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(8),
                      child: const Center(
                        child: Text(
                          'Selesai',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return modal
        .animate()
        .fadeIn(duration: 250.ms)
        .scale(
          begin: const Offset(0.85, 0.85),
          end: const Offset(1, 1),
          duration: 250.ms,
          curve: Curves.easeOutBack,
        );
  }

  Widget _row(String label, String value) =>
      _amountRow(label, value, compact: true);

  Widget _amountRow(
    String label,
    String value, {
    bool compact = false,
    bool bold = false,
    Color? valueColor,
  }) {
    final fontSize = compact ? 11.0 : 14.0;
    final weight = bold || !compact ? FontWeight.w700 : FontWeight.normal;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: weight,
                color: bold ? const Color(0xFF111111) : const Color(0xFF888888),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: weight,
                  color:
                      valueColor ??
                      (bold
                          ? const Color(0xFF111111)
                          : const Color(0xFF888888)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiptDivider extends StatelessWidget {
  const _ReceiptDivider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: Divider(height: 0.5, thickness: 0.5, color: Color(0xFFE0E0E0)),
  );
}

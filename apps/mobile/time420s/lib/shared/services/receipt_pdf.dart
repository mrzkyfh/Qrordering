import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/order.dart';
import '../models/enums.dart';
import 'receipt_builder.dart' show OutletReceiptInfo;

/// Struk digital (PDF) untuk dibagikan via WhatsApp/email/simpan lewat share
/// sheet OS. Memakai paket `pdf` (bundle dari `printing`) — tanpa dependency baru.
Future<void> shareReceiptPdf({
  required Order order,
  required OutletReceiptInfo outlet,
}) async {
  final bytes = await _buildReceiptPdf(order: order, outlet: outlet);
  await Printing.sharePdf(
    bytes: bytes,
    filename: 'Struk-${order.orderNumber}.pdf',
  );
}

Future<Uint8List> _buildReceiptPdf({
  required Order order,
  required OutletReceiptInfo outlet,
}) async {
  final doc = pw.Document();
  final rp = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp',
    decimalDigits: 0,
  );
  final df = DateFormat('d MMM yyyy, HH:mm', 'id_ID');
  final fmt = PdfPageFormat(
    72 * PdfPageFormat.mm,
    PdfPageFormat.a4.height,
    marginAll: 10,
  );
  final payments = <PaymentMethod, double>{};
  for (final payment in order.payments ?? const <Payment>[]) {
    payments.update(
      payment.method,
      (amount) => amount + payment.amount,
      ifAbsent: () => payment.amount,
    );
  }

  pw.Widget kv(String k, String v, {bool bold = false}) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text(
        k,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
      pw.Text(
        v,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    ],
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: fmt,
      build: (ctx) => [
        pw.Center(
          child: pw.Text(
            outlet.name,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
        ),
        if (outlet.address.isNotEmpty)
          pw.Center(
            child: pw.Text(
              outlet.address,
              style: const pw.TextStyle(fontSize: 8),
            ),
          ),
        if (outlet.phone.isNotEmpty)
          pw.Center(
            child: pw.Text(
              'Telp: ${outlet.phone}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ),
        pw.SizedBox(height: 6),
        pw.Divider(height: 6),
        if (order.orderType == OrderType.selfOrder && !order.isFullyPaid) ...[
          pw.Center(
            child: pw.Text(
              'ORDER QR - BELUM DIBAYAR',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Divider(height: 6),
        ],
        kv('No', '#${order.orderNumber}'),
        kv('Tanggal', df.format(order.createdAt.toLocal())),
        if ((order.customerName ?? '').isNotEmpty)
          kv('Pelanggan', order.customerName!),
        kv('Jenis Order', order.operationalOrderTypeLabel),
        if (order.shouldDisplayTable) kv('Nomor Meja', order.tableNumber!),
        if (order.customerOrderNote != null) ...[
          pw.SizedBox(height: 3),
          pw.Text(
            'Catatan Order:',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            order.customerOrderNote!,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
        pw.Divider(height: 6),
        ...(order.items ?? const <OrderItem>[]).expand(
          (it) => [
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 1),
              child: pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      '${it.quantity}x ${it.menuItem?.name ?? 'Item'}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  ),
                  pw.Text(
                    rp.format(it.subtotal),
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ),
            ...it.options.map(
              (option) => pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8),
                child: pw.Text(
                  option.price > 0
                      ? '+ ${option.optionName} (+${rp.format(option.price)})'
                      : '+ ${option.optionName}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ),
            ),
            if (it.notes?.trim().isNotEmpty == true)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8),
                child: pw.Text(
                  'Catatan: ${it.notes!.trim()}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ),
          ],
        ),
        pw.Divider(height: 6),
        kv('Subtotal', rp.format(order.subtotal)),
        if (order.discountAmount > 0)
          kv('Diskon', '-${rp.format(order.discountAmount)}'),
        if (order.taxAmount > 0) kv('Pajak', rp.format(order.taxAmount)),
        if (order.serviceCharge > 0)
          kv('Servis', rp.format(order.serviceCharge)),
        pw.SizedBox(height: 2),
        kv('TOTAL', rp.format(order.totalAmount), bold: true),
        if (payments.isNotEmpty) ...[
          pw.Divider(height: 6),
          ...payments.entries.map(
            (entry) => kv(entry.key.label, rp.format(entry.value)),
          ),
        ],
        if (outlet.taxInclusive && order.taxAmount > 0) ...[
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              'Harga sudah termasuk ${outlet.taxName} senilai ${rp.format(order.taxAmount)}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ),
        ],
        pw.SizedBox(height: 10),
        for (final line in outlet.receipt.footer.split('\n'))
          if (line.trim().isNotEmpty)
            pw.Center(
              child: pw.Text(
                line.trim(),
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),
        if (outlet.receipt.footer.trim().isEmpty)
          pw.Center(
            child: pw.Text(
              'Terima kasih',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
      ],
    ),
  );

  return doc.save();
}

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:time420s/shared/models/shift_close_report.dart';
import 'package:time420s/shared/services/receipt_builder.dart';
import 'package:time420s/shared/services/shift_close_report_print.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('id_ID'));

  ShiftCloseReport report({bool provisional = false}) => ShiftCloseReport(
    shiftId: 'shift-1',
    outletId: 'outlet-1',
    outlet: const OutletReceiptInfo(
      name: 'Time 420s',
      address: 'Jalan Contoh, Bekasi',
      phone: '08123456789',
      city: 'Bekasi',
    ),
    cashierId: 'cashier-1',
    cashierName: 'Dino M',
    openedAt: DateTime.utc(2026, 7, 24, 4, 47),
    closedAt: DateTime.utc(2026, 7, 24, 16, 11),
    openingCash: 0,
    closingCash: 1098350,
    expectedCash: 1098350,
    cashDifference: 0,
    cashReceived: 1098350,
    nonCashReceived: 0,
    totalReceipts: 1098350,
    taxTotal: 0,
    serviceChargeTotal: 99850,
    discountTotal: 0,
    refundTotal: 0,
    cashIn: 0,
    cashOut: 45000,
    completedTransactions: 19,
    unpaidTransactions: 0,
    voidItemQuantity: 1,
    voidItemAmount: 20000,
    productQuantity: 32,
    paymentMethods: const [
      ShiftPaymentSummary(method: 'cash', amount: 1098350),
    ],
    products: const [
      ShiftProductSummary(name: 'Cheesy Double', quantity: 3, amount: 75000),
      ShiftProductSummary(
        name: 'Beef Cheese With Egg',
        quantity: 9,
        amount: 270000,
      ),
    ],
    expenses: [
      ShiftExpenseSummary(
        id: 'expense-1',
        category: 'bahan_baku',
        description: 'Belanja bahan baku tambahan untuk dapur',
        amount: 30000,
        createdAt: DateTime.utc(2026, 7, 24, 9, 10),
      ),
      ShiftExpenseSummary(
        id: 'expense-2',
        category: 'operasional',
        description: 'Isi ulang gas',
        amount: 15000,
        createdAt: DateTime.utc(2026, 7, 24, 10, 20),
      ),
    ],
    isProvisional: provisional,
  );

  test('model laporan membaca angka server dan daftar produk', () {
    final parsed = ShiftCloseReport.fromJson({
      'shift_id': 'shift-1',
      'outlet_id': 'outlet-1',
      'outlet': {'name': 'Time 420s', 'settings': <String, dynamic>{}},
      'cashier_id': 'cashier-1',
      'cashier_name': 'Dino M',
      'opened_at': '2026-07-24T04:47:00.000Z',
      'closed_at': '2026-07-24T16:11:00.000Z',
      'opening_cash': 0,
      'closing_cash': 1098350,
      'expected_cash': 1098350,
      'cash_difference': 0,
      'cash_received': 1098350,
      'non_cash_received': 0,
      'total_receipts': 1098350,
      'tax_total': 0,
      'service_charge_total': 99850,
      'discount_total': 0,
      'refund_total': 0,
      'cash_in': 0,
      'cash_out': 30000,
      'completed_transactions': 19,
      'unpaid_transactions': 0,
      'void_item_quantity': 1,
      'void_item_amount': 20000,
      'product_quantity': 3,
      'payment_methods': [
        {'method': 'cash', 'amount': 1098350},
      ],
      'products': [
        {'name': 'Cheesy Double', 'quantity': 3, 'amount': 75000},
      ],
      'expenses': [
        {
          'id': 'expense-1',
          'category': 'bahan_baku',
          'description': 'Belanja bahan',
          'amount': 30000,
          'created_at': '2026-07-24T09:10:00.000Z',
        },
      ],
    });

    expect(parsed.cashierName, 'Dino M');
    expect(parsed.cashReceived, 1098350);
    expect(parsed.products.single.name, 'Cheesy Double');
    expect(parsed.products.single.quantity, 3);
    expect(parsed.cashOut, 30000);
    expect(parsed.expenses.single.description, 'Belanja bahan');
    expect(parsed.expenses.single.category, 'bahan_baku');
  });

  test('struk 58 mm memuat ringkasan transaksi dan penjualan menu', () async {
    final bytes = await ShiftCloseReportBuilder(
      report: report(),
      paperSize: PaperSize.mm58,
    ).build();
    final output = String.fromCharCodes(bytes);

    expect(output, contains('TIME 420S'));
    expect(output, contains('LAPORAN TUTUP KASIR'));
    expect(output, contains('TRANSAKSI PENJUALAN'));
    expect(output, contains('Dino M'));
    expect(output, contains('1.098.350'));
    expect(output, contains('Pengeluaran Kas'));
    expect(output, contains('-45.000'));
    expect(output, contains('PENGELUARAN KASIR'));
    expect(output, contains('Belanja bahan baku'));
    expect(output, contains('BAHAN BAKU'));
    expect(output, contains('TOTAL PENGELUARAN'));
    expect(output, contains('45.000'));
    expect(output, contains('PENJUALAN MENU'));
    expect(output, contains('CHEESY DOUBLE'));
    expect(output, contains('BEEF CHEESE WITH EGG'));
    expect(output, contains('Total Produk'));
    expect(output, contains('INFORMASI SHIFT'));
    expect(output, contains('PENERIMAAN'));
    expect(output, contains('REKONSILIASI KAS'));
    expect(output, contains('RINGKASAN TRANSAKSI'));
    expect(output, contains('Kasir Dino M'));

    // Font A dan lebar 32 karakter dipakai agar hasil konsisten pada printer
    // 58 mm yang tidak selalu mematuhi perintah Font B.
    expect(bytes, containsAllInOrder([27, 77, 0]));
    var feedCommands = 0;
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 27 && bytes[i + 1] == 100) feedCommands++;
    }
    expect(feedCommands, 3);
  });

  test('struk 80 mm tetap memakai susunan kolom yang rapi', () async {
    final bytes = await ShiftCloseReportBuilder(
      report: report(),
      paperSize: PaperSize.mm80,
    ).build();
    final output = String.fromCharCodes(bytes);

    expect(output, contains('Kasir Dino M'));
    expect(output, contains('PENGELUARAN KASIR'));
    expect(output, contains('BAHAN BAKU'));
    expect(bytes, containsAllInOrder([27, 77, 0]));
  });

  test('produk terjual dapat dikecualikan dari cetakan tutup kasir', () async {
    final bytes = await ShiftCloseReportBuilder(
      report: report(),
      paperSize: PaperSize.mm58,
      includeProducts: false,
    ).build();
    final output = String.fromCharCodes(bytes);

    expect(output, contains('TRANSAKSI PENJUALAN'));
    expect(output, contains('Total Penerimaan'));
    expect(output, isNot(contains('PENJUALAN MENU')));
    expect(output, isNot(contains('CHEESY DOUBLE')));
    expect(output, isNot(contains('Total Produk')));
  });

  test('laporan offline tercetak jelas sebagai laporan sementara', () async {
    final bytes = await ShiftCloseReportBuilder(
      report: report(provisional: true),
      paperSize: PaperSize.mm58,
      includeProducts: false,
    ).build();

    expect(
      String.fromCharCodes(bytes),
      contains('SEMENTARA - MENUNGGU SINKRONISASI'),
    );
  });
}

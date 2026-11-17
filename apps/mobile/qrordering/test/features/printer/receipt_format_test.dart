import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/order.dart';
import 'package:qrordering/shared/services/receipt_builder.dart';

int _indexOfSequence(List<int> bytes, List<int> sequence) {
  for (var i = 0; i <= bytes.length - sequence.length; i++) {
    var matches = true;
    for (var j = 0; j < sequence.length; j++) {
      if (bytes[i + j] != sequence[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

/// Regresi format struk: titik dua di kolom kiri harus SEJAJAR satu kolom
/// (dulu `'$key :'` menaruh titik dua tepat setelah label sehingga mengambang
/// mengikuti panjang label — "No Nota :", "Kasir Order :", "Dilayani :" tidak
/// rata). ReceiptBuilder.kvLabel mem-pad label ke lebar tetap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('id_ID'));

  test(
    'struk berakhir dengan tiga feed dan cut tanpa lima LF bawaan',
    () async {
      final now = DateTime(2026, 10, 8, 10);
      final order = Order(
        id: 'order-gap',
        outletId: 'outlet-1',
        orderNumber: 'GAP-001',
        orderType: OrderType.dineIn,
        status: OrderStatus.paid,
        subtotal: 10000,
        discountAmount: 0,
        taxAmount: 0,
        serviceCharge: 0,
        totalAmount: 10000,
        stockDeducted: true,
        createdAt: now,
        updatedAt: now,
      );
      final bytes = await ReceiptBuilder(
        outlet: const OutletReceiptInfo(
          name: 'QrOrdering',
          receipt: ReceiptConfig(showLogo: false),
        ),
      ).build(order: order);

      expect(bytes.sublist(bytes.length - 6), [27, 100, 3, 29, 86, 48]);
      expect(String.fromCharCodes(bytes), isNot(contains('\n\n\n\n\n')));
    },
  );

  // Semua label baris metadata & ringkasan yang dipakai di struk.
  const labels = [
    'No Nota',
    'Waktu',
    'Kasir Order',
    'Kasir Bayar',
    'Customer',
    'Dilayani',
    'Jenis Order',
    'Nama Order',
    'Nomor Meja',
    'Subtotal',
    'Diskon',
    'Service 2%',
    'PPN 10%',
    'Tunai',
    'Kembali',
  ];

  group('ReceiptBuilder.kvLabel — perataan titik dua', () {
    test('titik dua berada di kolom yang SAMA untuk semua label', () {
      final colonPositions = labels
          .map((l) => ReceiptBuilder.kvLabel(l).indexOf(':'))
          .toSet();
      // Satu posisi unik = semua titik dua sejajar vertikal.
      expect(
        colonPositions.length,
        1,
        reason: 'Titik dua tidak sejajar: $colonPositions',
      );
    });

    test('label pendek di-pad kanan (bukan nempel titik dua)', () {
      // "Waktu" (5) di-pad hingga titik dua sejajar dengan label terpanjang.
      final waktu = ReceiptBuilder.kvLabel('Waktu');
      expect(waktu.startsWith('Waktu '), isTrue);
      expect(waktu.endsWith(':'), isTrue);
      expect(
        waktu.indexOf(':'),
        ReceiptBuilder.kvLabel('Kasir Order').indexOf(':'),
      );
    });

    test(
      'muat di kolom label 58mm (width 5 = 13 karakter) tanpa membungkus',
      () {
        for (final l in labels) {
          expect(
            ReceiptBuilder.kvLabel(l).length,
            lessThanOrEqualTo(13),
            reason: 'Label "$l" terlalu panjang untuk kolom 58mm',
          );
        }
      },
    );

    test(
      'label lebih panjang dari padding tidak terpotong (degradasi aman)',
      () {
        const long = 'Label Sangat Panjang';
        final out = ReceiptBuilder.kvLabel(long);
        expect(out, '$long:');
      },
    );
  });

  group(
    'ReceiptBuilder.wrapText — teks panjang tidak pecah di tengah kata',
    () {
      test('nama menu tidak meninggalkan satu huruf di baris berikutnya', () {
        expect(ReceiptBuilder.wrapText('MATCHA CREAMY VANILLA', 20), [
          'MATCHA CREAMY',
          'VANILLA',
        ]);
      });

      test('jenis order dan alamat dibungkus pada batas kata', () {
        expect(ReceiptBuilder.wrapText('QR - Makan di Tempat', 18), [
          'QR - Makan di',
          'Tempat',
        ]);
        expect(
          ReceiptBuilder.wrapText(
            'Walantakan, Kec. Langowan Utara Kabupaten Minahasa-Sulawesi Utara',
            32,
          ),
          [
            'Walantakan, Kec. Langowan Utara',
            'Kabupaten Minahasa-Sulawesi',
            'Utara',
          ],
        );
      });
    },
  );

  test('struk 58mm merapikan metadata dan nama menu panjang', () async {
    final now = DateTime(2026, 10, 5, 18, 25);
    final item = OrderItem(
      id: 'item-long',
      orderId: 'order-long',
      menuItemId: 'menu-long',
      quantity: 1,
      unitPrice: 23000,
      subtotal: 23000,
      menuItem: const MenuItem(
        id: 'menu-long',
        outletId: 'outlet-1',
        name: 'MATCHA CREAMY VANILLA',
        price: 23000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      ),
    );
    final order = Order(
      id: 'order-long',
      outletId: 'outlet-1',
      tableId: 'table-25',
      tableNumber: '25',
      orderNumber: '087',
      orderType: OrderType.selfOrder,
      status: OrderStatus.confirmed,
      customerName: 'Bella',
      notes: 'Jenis layanan: Makan di Tempat · Meja 25',
      subtotal: 23000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 23000,
      stockDeducted: true,
      createdAt: now,
      updatedAt: now,
      items: [item],
    );
    const outlet = OutletReceiptInfo(
      name: 'QrOrdering',
      address:
          'Walantakan, Kec. Langowan Utara Kabupaten Minahasa-Sulawesi Utara',
      receipt: ReceiptConfig(
        showLogo: false,
        showAddress: true,
        showOrderType: true,
        showTable: true,
      ),
    );

    final bytes = await ReceiptBuilder(
      outlet: outlet,
      paperSize: PaperSize.mm58,
    ).build(order: order, customerName: order.customerName);
    final output = String.fromCharCodes(bytes);

    expect(output, contains('Walantakan, Kec. Langowan Utara'));
    expect(output, contains('Kabupaten Minahasa-Sulawesi'));
    expect(output, contains('MAKAN DI TEMPAT - MEJA 25'));
    expect(output, isNot(contains('Jenis Order')));
    expect(output, isNot(contains('Nomor Meja')));
    expect(output, contains('MATCHA CREAMY'));
    expect(output, contains('VANILLA'));
  });

  test(
    'header struk fisik memakai jarak baris yang sama lapangnya dengan preview',
    () async {
      final now = DateTime(2026, 7, 24, 12, 6);
      final order = Order(
        id: 'order-1',
        outletId: 'outlet-1',
        orderNumber: 'P7-001',
        orderType: OrderType.dineIn,
        status: OrderStatus.paid,
        subtotal: 10000,
        discountAmount: 0,
        taxAmount: 0,
        serviceCharge: 0,
        totalAmount: 10000,
        stockDeducted: true,
        createdAt: now,
        updatedAt: now,
      );
      const outlet = OutletReceiptInfo(
        name: 'QR Ordering',
        address: 'Jl. Contoh No. 1',
        phone: '085',
        city: 'Bekasi',
        receipt: ReceiptConfig(
          showLogo: false,
          showOutletName: true,
          showAddress: true,
          showPhone: true,
          showCity: true,
        ),
      );

      final bytes = await ReceiptBuilder(
        outlet: outlet,
        paperSize: PaperSize.mm58,
      ).build(order: order);
      final output = String.fromCharCodes(bytes);
      final sectionGap = _indexOfSequence(bytes, [
        0x1b,
        0x4a,
        ReceiptBuilder.headerSectionGapDots,
      ]);
      final looseLines = _indexOfSequence(bytes, [
        0x1b,
        0x33,
        ReceiptBuilder.headerLineSpacingDots,
      ]);
      final resetLines = _indexOfSequence(bytes, const [0x1b, 0x32]);

      expect(output, contains('QR Ordering'));
      expect(output, contains('Jl. Contoh No. 1'));
      expect(output, contains('Telp: 085'));
      expect(output, contains('Bekasi'));
      expect(sectionGap, greaterThanOrEqualTo(0));
      expect(looseLines, greaterThan(sectionGap));
      expect(resetLines, greaterThan(looseLines));
    },
  );

  test('struk split bill menampilkan semua metode dan nominalnya', () async {
    final now = DateTime(2026, 7, 29, 12);
    final order = Order(
      id: 'order-split',
      outletId: 'outlet-1',
      orderNumber: 'P7-009',
      orderType: OrderType.dineIn,
      status: OrderStatus.paid,
      subtotal: 100000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 100000,
      stockDeducted: true,
      createdAt: now,
      updatedAt: now,
    );
    const outlet = OutletReceiptInfo(
      name: 'QR Ordering',
      receipt: ReceiptConfig(showLogo: false),
    );

    final bytes =
        await ReceiptBuilder(outlet: outlet, paperSize: PaperSize.mm58).build(
          order: order,
          // Dua pembayaran tunai digabung menjadi satu baris agar struk ringkas.
          paymentBreakdown: const {
            PaymentMethod.cash: 40000,
            PaymentMethod.qris: 35000,
            PaymentMethod.debit: 25000,
          },
        );
    final output = String.fromCharCodes(bytes);

    expect(output, contains('Tunai'));
    expect(output, contains('QRIS'));
    expect(output, contains('Debit'));
    expect(output, contains('40.000'));
    expect(output, contains('35.000'));
    expect(output, contains('25.000'));
  });

  test('bill manual menampilkan penanda belum lunas', () async {
    final now = DateTime(2026, 10, 1, 12);
    final order = Order(
      id: 'bill-1',
      outletId: 'outlet-1',
      orderNumber: 'B-001',
      orderType: OrderType.dineIn,
      status: OrderStatus.confirmed,
      subtotal: 25000,
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: 25000,
      stockDeducted: true,
      createdAt: now,
      updatedAt: now,
    );
    const outlet = OutletReceiptInfo(
      name: 'QR Ordering',
      receipt: ReceiptConfig(showLogo: false),
    );

    final bytes = await ReceiptBuilder(
      outlet: outlet,
      paperSize: PaperSize.mm58,
    ).build(order: order, documentTitle: 'BILL - BELUM LUNAS');

    final output = String.fromCharCodes(bytes);
    expect(output, contains('BILL - BELUM'));
    expect(output, contains('LUNAS'));
  });

  test('rincian pembayaran menggabungkan metode yang sama', () {
    final now = DateTime(2026, 7, 29, 12);
    final breakdown = receiptPaymentBreakdown([
      Payment(
        id: 'p1',
        orderId: 'o1',
        outletId: 'outlet-1',
        method: PaymentMethod.cash,
        amount: 10000,
        paidAt: now,
      ),
      Payment(
        id: 'p2',
        orderId: 'o1',
        outletId: 'outlet-1',
        method: PaymentMethod.cash,
        amount: 5000,
        paidAt: now,
      ),
      Payment(
        id: 'p3',
        orderId: 'o1',
        outletId: 'outlet-1',
        method: PaymentMethod.qris,
        amount: 20000,
        paidAt: now,
      ),
    ]);

    expect(breakdown, {PaymentMethod.cash: 15000, PaymentMethod.qris: 20000});
  });

  test(
    'struk order QR menandai belum dibayar, layanan, dan catatan pelanggan',
    () async {
      final now = DateTime(2026, 8, 21, 12);
      final order = Order(
        id: 'order-qr',
        outletId: 'outlet-1',
        tableId: 'table-a1',
        tableNumber: 'A1',
        orderNumber: 'QR-001',
        orderType: OrderType.selfOrder,
        status: OrderStatus.draft,
        customerName: 'Siti',
        notes: 'Jenis layanan: Bawa Pulang\nAntar semua menu bersamaan',
        subtotal: 25000,
        discountAmount: 0,
        taxAmount: 0,
        serviceCharge: 0,
        totalAmount: 25000,
        stockDeducted: false,
        createdAt: now,
        updatedAt: now,
      );
      const outlet = OutletReceiptInfo(
        name: 'QR Ordering',
        receipt: ReceiptConfig(showLogo: false),
      );

      final bytes = await ReceiptBuilder(
        outlet: outlet,
        paperSize: PaperSize.mm58,
      ).build(order: order, customerName: order.customerName);
      final output = String.fromCharCodes(bytes);

      expect(output, contains('ORDER QR - BELUM'));
      expect(output, contains('DIBAYAR'));
      expect(output, contains('BAWA PULANG'));
      expect(output, contains('CATATAN ORDER'));
      expect(output, contains('ANTAR SEMUA MENU BERSAMAAN'));
      expect(output, isNot(contains('Nomor Meja')));
      expect('Siti'.allMatches(output).length, 1);
    },
  );

  test(
    'struk tepat setelah pembayaran QR tidak memakai status snapshot lama',
    () async {
      final now = DateTime(2026, 8, 26, 12);
      final staleOrder = Order(
        id: 'order-qr-paid',
        outletId: 'outlet-1',
        tableId: 'table-1',
        tableNumber: '1',
        orderNumber: 'QR-009',
        orderType: OrderType.selfOrder,
        status: OrderStatus.confirmed,
        customerName: 'Kiki',
        notes: 'Jenis layanan: Makan di Tempat · Meja 1',
        subtotal: 50000,
        discountAmount: 0,
        taxAmount: 5000,
        serviceCharge: 1000,
        totalAmount: 56000,
        stockDeducted: true,
        createdAt: now,
        updatedAt: now,
      );
      const outlet = OutletReceiptInfo(
        name: 'QR Ordering',
        receipt: ReceiptConfig(showLogo: false),
      );

      final bytes =
          await ReceiptBuilder(outlet: outlet, paperSize: PaperSize.mm58).build(
            order: staleOrder,
            paymentMethod: PaymentMethod.cash,
            cashReceived: 60000,
          );
      final output = String.fromCharCodes(bytes);

      expect(output, isNot(contains('ORDER QR - BELUM DIBAYAR')));
      expect(output, contains('Tunai'));
    },
  );
}

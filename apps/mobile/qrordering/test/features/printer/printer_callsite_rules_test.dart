import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qrordering/features/pos/presentation/pages/device_settings_page.dart'
    show isValidIpv4, printerRoleLabel, printerWithAddedRole;
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/order.dart';
import 'package:qrordering/shared/services/printer_service.dart';
import 'package:qrordering/shared/services/void_receipt_print.dart';

/// Regresi untuk audit Perangkat.
///
/// Tes printer yang sudah ada menguji ATURAN-nya (printerForReceipt, filter
/// kategori, round-trip) dan semuanya hijau — tapi setiap bug di bawah hidup di
/// PEMANGGIL aturan itu, yang tak satu pun diuji. Berkas ini mengunci kontrak
/// yang dipegang para pemanggil.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('aksi Void order dan item hanya memakai struk Kasir Utama', () async {
    for (final path in [
      'lib/features/orders/presentation/widgets/void_order_dialog.dart',
      'lib/features/orders/presentation/widgets/item_void_dialog.dart',
    ]) {
      final source = await File(path).readAsString();
      expect(source, contains('printVoidReceipt('));
      expect(source, isNot(contains('KitchenTrigger.voidOrder')));
      expect(source, isNot(contains('printKitchenVoidTicketsForItems(')));
    }
  });

  test('order QR realtime memakai trigger autoprint QR khusus', () async {
    final source = await File(
      'lib/shared/services/notification_service.dart',
    ).readAsString();

    expect(source, contains('trigger: KitchenTrigger.qrOrder'));
    expect(source, contains('claimBeforePrint: true'));
    expect(source, contains('skipIfAlreadyPrinted: true'));
  });

  test('kirim ke dapur manual juga memakai klaim eksklusif', () async {
    final source = await File(
      'lib/features/orders/presentation/bloc/orders_bloc.dart',
    ).readAsString();

    expect(source, contains('trigger: KitchenTrigger.order'));
    expect(source, contains('claimBeforePrint: true'));
    expect(source, contains('skipIfAlreadyPrinted: true'));
  });

  test('pembayaran memproses dapur sebelum mencoba printer struk', () async {
    final source = await File(
      'lib/features/orders/presentation/pages/order_list_page.dart',
    ).readAsString();
    final paymentStart = source.indexOf(
      '// Tiket dapur didahulukan agar proses produksi',
    );
    final kitchenCall = source.indexOf(
      'await printKitchenTicketsForOrder(',
      paymentStart,
    );
    final receiptCall = source.indexOf('await _tryPrintReceipt(', paymentStart);

    expect(paymentStart, greaterThanOrEqualTo(0));
    expect(kitchenCall, greaterThan(paymentStart));
    expect(receiptCall, greaterThan(kitchenCall));
  });

  test(
    'split payment order tersimpan dan QR mencetak struk setelah finalisasi',
    () async {
      final source = await File(
        'lib/features/orders/presentation/pages/order_list_page.dart',
      ).readAsString();
      final splitStart = source.indexOf('class _SplitBillSheetState');
      final splitEnd = source.indexOf('class _PaymentSheet', splitStart);
      final splitSection = source.substring(splitStart, splitEnd);
      final printStart = source.indexOf(
        'Future<void> _tryPrintFinalizedSplitReceipt',
      );
      final printSection = source.substring(printStart);

      expect(
        splitSection,
        contains('await _tryPrintFinalizedSplitReceipt('),
        reason: 'finalisasi split harus memicu struk untuk semua jenis order',
      );
      expect(printSection, contains('payments(method, amount)'));
      expect(printSection, contains('paymentBreakdown: paymentBreakdown'));
      expect(
        source,
        contains('printer.printReceiptBytes(bytes, auto: true)'),
        reason:
            'cetak setelah pembayaran harus mengikuti toggle Autoprint Bayar',
      );
    },
  );

  test('tab Dapur menyediakan toggle Autoprint Pesanan QR', () async {
    final source = await File(
      'lib/features/pos/presentation/pages/device_settings_page.dart',
    ).readAsString();

    expect(source, contains("'Autoprint Pesanan QR'"));
    expect(source, contains('_p.copyWith(autoQrOrder: v)'));
    expect(source, contains('Aktifkan hanya pada satu kasir utama.'));
  });

  group('label peran printer di daftar perangkat', () {
    test('printer multi-peran terlihat sebagai Struk + Dapur', () {
      const printer = SavedPrinter(
        id: 'multi',
        name: 'RPP02',
        jenis: 'kasir',
        strukEnabled: true,
        dapurEnabled: true,
      );

      expect(printerRoleLabel(printer), 'Printer Struk + Dapur');
    });

    test('printer dapur saja tetap terlihat sebagai Printer Dapur', () {
      const printer = SavedPrinter(
        id: 'dapur',
        name: 'Dapur',
        jenis: 'dapur',
        strukEnabled: false,
        dapurEnabled: true,
      );

      expect(printerRoleLabel(printer), 'Printer Dapur');
    });
  });

  group('wizard menambah peran pada printer yang sudah terdaftar', () {
    test(
      'printer Struk yang dipilih sebagai Dapur mengaktifkan kedua peran',
      () {
        const existing = SavedPrinter(
          id: 'rpp',
          name: 'RPP02',
          mac: 'AA:BB:CC:DD:EE:FF',
          jenis: 'kasir',
          strukEnabled: true,
          dapurEnabled: false,
          autoOrder: false,
        );

        final updated = printerWithAddedRole(existing, 'dapur');

        expect(updated.strukEnabled, true);
        expect(updated.dapurEnabled, true);
        expect(updated.autoOrder, true);
        expect(printerRoleLabel(updated), 'Printer Struk + Dapur');
      },
    );

    test('menambah peran Dapur tidak menghapus pengaturan printer lama', () {
      const existing = SavedPrinter(
        id: 'rpp',
        name: 'RPP02',
        paper: '80',
        copies: 2,
        categories: ['makanan'],
        strukEnabled: true,
      );

      final updated = printerWithAddedRole(existing, 'dapur');

      expect(updated.paper, '80');
      expect(updated.copies, 2);
      expect(updated.categories, ['makanan']);
    });
  });

  group(
    'receiptNeedsBluetoothConnect — printer LAN tak boleh digerbangi BT',
    () {
      test('printer struk LAN → tidak perlu koneksi Bluetooth', () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'l1',
            name: 'Kasir LAN',
            type: 'lan',
            host: '192.168.1.50',
            jenis: 'kasir',
          ),
        );
        // Dulu pemanggil menulis `if (!isConnected) { ...dialog scan BT... }`.
        // isConnected selamanya false untuk LAN → struk TAK PERNAH keluar dan
        // kasir malah disodori dialog Bluetooth.
        expect(await ps.receiptNeedsBluetoothConnect(), false);
      });

      test('printer struk Bluetooth → tetap perlu koneksi', () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'b1',
            name: 'Kasir BT',
            mac: 'AA:BB:CC:DD:EE:FF',
            jenis: 'kasir',
          ),
        );
        expect(await ps.receiptNeedsBluetoothConnect(), true);
      });

      test(
        'registry kosong → jalur legacy 1-printer, tetap perlu BT',
        () async {
          expect(await PrinterService().receiptNeedsBluetoothConnect(), true);
        },
      );

      test(
        'tak ada printer ber-peran Struk → tak ada yang perlu disambung',
        () async {
          final ps = PrinterService();
          await ps.savePrinter(
            const SavedPrinter(
              id: 'd1',
              name: 'Dapur',
              mac: 'AA:BB:CC:DD:EE:01',
              jenis: 'dapur',
              strukEnabled: false,
              dapurEnabled: true,
            ),
          );
          expect(await ps.receiptNeedsBluetoothConnect(), false);
        },
      );
    },
  );

  group(
    'printReceiptBytes — "dilewati" tak boleh menyamar jadi "tercetak"',
    () {
      test('autoprint bayar mati → skipped, BUKAN printed', () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'k1',
            name: 'Kasir',
            mac: 'AA:BB:CC:DD:EE:FF',
            jenis: 'kasir',
            strukAutoBayar: false,
          ),
        );
        final outcome = await ps.printReceiptBytes(const [1, 2, 3], auto: true);

        // Dulu ini `true`. Pemanggil lalu memanggil markReceiptPrinted(), dan
        // dengan Batas Cetak aktif struk itu jadi TAK BISA dicetak ulang
        // selamanya — padahal ia tak pernah keluar sekali pun.
        expect(outcome, PrintOutcome.skipped);
        expect(
          outcome.isPrinted,
          false,
          reason: 'tidak boleh ditandai tercetak',
        );
        expect(
          outcome.isFailed,
          false,
          reason: 'bukan gagal → jangan toast error',
        );
      });

      test(
        'cetak manual mengabaikan toggle autoprint (tidak skipped)',
        () async {
          final ps = PrinterService();
          await ps.savePrinter(
            const SavedPrinter(
              id: 'l1',
              name: 'Kasir LAN',
              type: 'lan',
              host: '127.0.0.1',
              port:
                  1, // pasti gagal connect → failed, yang penting BUKAN skipped
              jenis: 'kasir',
              strukAutoBayar: false,
            ),
          );
          final outcome = await ps.printReceiptBytes(const [1, 2, 3]);
          expect(
            outcome,
            PrintOutcome.failed,
            reason: 'manual harus mencoba mencetak walau autoprint mati',
          );
        },
      );

      test('tak ada printer ber-peran Struk → skipped', () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'd1',
            name: 'Dapur',
            mac: 'AA:BB:CC:DD:EE:01',
            jenis: 'dapur',
            strukEnabled: false,
            dapurEnabled: true,
          ),
        );
        expect(await ps.printReceiptBytes(const [1]), PrintOutcome.skipped);
      });
    },
  );

  test('autoprint struk order QR dapat dimatikan per printer', () async {
    final ps = PrinterService();
    await ps.savePrinter(
      const SavedPrinter(
        id: 'qr-off',
        name: 'Kasir LAN',
        type: 'lan',
        host: '127.0.0.1',
        port: 1,
        jenis: 'kasir',
        strukAutoOrder: false,
      ),
    );

    expect(
      await ps.printIncomingOrderReceiptBytes(const [1, 2, 3]),
      PrintOutcome.skipped,
    );
  });

  test(
    'struk Void dilewati dengan aman bila printer Struk belum aktif',
    () async {
      final now = DateTime(2026, 7, 24, 10);
      final order = Order(
        id: 'order-void',
        outletId: 'outlet-1',
        orderNumber: 'ORD-VOID-001',
        orderType: OrderType.dineIn,
        status: OrderStatus.void_,
        subtotal: 20000,
        discountAmount: 0,
        taxAmount: 0,
        serviceCharge: 0,
        totalAmount: 20000,
        stockDeducted: false,
        createdAt: now,
        updatedAt: now,
      );

      expect(
        await printVoidReceipt(order: order, reason: 'Salah pesanan'),
        PrintOutcome.skipped,
      );
    },
  );

  group('savePrinter — dedup alamat fisik (biang printer ganda)', () {
    test('MAC sama, id baru → tetap SATU entri', () async {
      final ps = PrinterService();
      // Wizard "Tambah Perangkat" membuat id dari timestamp, jadi menambahkan
      // printer yang sama dua kali selalu menghasilkan id berbeda.
      await ps.savePrinter(
        const SavedPrinter(
          id: '1700000000',
          name: 'RPP02',
          mac: 'AA:BB:CC:DD:EE:FF',
        ),
      );
      await ps.savePrinter(
        const SavedPrinter(
          id: '1700000999',
          name: 'RPP02',
          mac: 'AA:BB:CC:DD:EE:FF',
        ),
      );

      final list = await ps.listPrinters();
      expect(list.length, 1, reason: 'satu printer fisik = satu entri');
      expect(list.single.id, '1700000999', reason: 'entri terbaru yang menang');
    });

    test(
      'printer fisik sama ditambah utk peran kedua → peran DIGABUNG, tak hilang',
      () async {
        final ps = PrinterService();
        // Tambah sbg KASIR (struk)
        await ps.savePrinter(
          const SavedPrinter(
            id: 'k',
            name: 'RPP02',
            mac: 'DC:0D:30:AA:BB:CC',
            jenis: 'kasir',
            strukEnabled: true,
            dapurEnabled: false,
          ),
        );
        // Tambah printer FISIK SAMA sbg DAPUR
        await ps.savePrinter(
          const SavedPrinter(
            id: 'd',
            name: 'RPP02',
            mac: 'DC:0D:30:AA:BB:CC',
            jenis: 'dapur',
            strukEnabled: false,
            dapurEnabled: true,
          ),
        );

        final list = await ps.listPrinters();
        expect(list.length, 1, reason: 'tetap satu entri fisik');
        // Dulu: struk HILANG (hanya dapur). Kini: KEDUA peran aktif.
        expect(
          list.single.strukEnabled,
          true,
          reason: 'peran struk lama TIDAK boleh hilang saat menambah dapur',
        );
        expect(
          list.single.dapurEnabled,
          true,
          reason: 'peran dapur baru ikut aktif',
        );
      },
    );

    test(
      'gabung peran mempertahankan kategori dapur lama bila entri baru kosong',
      () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'a',
            name: 'P',
            mac: 'AA:11',
            dapurEnabled: true,
            categories: ['cat-1', 'cat-2'],
          ),
        );
        await ps.savePrinter(
          const SavedPrinter(
            id: 'b',
            name: 'P',
            mac: 'AA:11',
            strukEnabled: true,
          ),
        );
        final p = (await ps.listPrinters()).single;
        expect(p.strukEnabled, true);
        expect(p.dapurEnabled, true);
        expect(p.categories, [
          'cat-1',
          'cat-2',
        ], reason: 'kategori lama terbawa');
      },
    );

    test('MAC beda huruf besar/kecil tetap dianggap sama', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'a', name: 'P', mac: 'aa:bb:cc:dd:ee:ff'),
      );
      await ps.savePrinter(
        const SavedPrinter(id: 'b', name: 'P', mac: 'AA:BB:CC:DD:EE:FF'),
      );
      expect((await ps.listPrinters()).length, 1);
    });

    test('LAN host:port sama → satu entri; port beda → dua entri', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'a',
          name: 'LAN',
          type: 'lan',
          host: '192.168.1.50',
          port: 9100,
        ),
      );
      await ps.savePrinter(
        const SavedPrinter(
          id: 'b',
          name: 'LAN',
          type: 'lan',
          host: '192.168.1.50',
          port: 9100,
        ),
      );
      expect((await ps.listPrinters()).length, 1);

      await ps.savePrinter(
        const SavedPrinter(
          id: 'c',
          name: 'LAN2',
          type: 'lan',
          host: '192.168.1.50',
          port: 9101,
        ),
      );
      expect(
        (await ps.listPrinters()).length,
        2,
        reason: 'port beda = printer berbeda',
      );
    });

    test('printer berbeda (MAC beda) tetap tersimpan dua-duanya', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'a', name: 'Kasir', mac: 'AA:BB:CC:DD:EE:01'),
      );
      await ps.savePrinter(
        const SavedPrinter(id: 'b', name: 'Dapur', mac: 'AA:BB:CC:DD:EE:02'),
      );
      expect((await ps.listPrinters()).length, 2);
    });

    test('default tak menggantung saat entri lama tergantikan', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'lama',
          name: 'Kasir',
          mac: 'AA:BB:CC:DD:EE:FF',
          jenis: 'kasir',
        ),
      );
      expect(await ps.defaultPrinterId(), 'lama');

      await ps.savePrinter(
        const SavedPrinter(
          id: 'baru',
          name: 'Kasir',
          mac: 'AA:BB:CC:DD:EE:FF',
          jenis: 'kasir',
        ),
      );

      // Default menunjuk id yang sudah tak ada → printerForReceipt() gagal
      // menemukannya. Harus diarahkan ulang.
      expect(await ps.defaultPrinterId(), 'baru');
      expect((await ps.printerForReceipt())?.id, 'baru');
    });
  });

  group('removePrinter — jangan tinggalkan MAC hantu', () {
    test('menghapus printer terakhir juga melupakan last-MAC-nya', () async {
      SharedPreferences.setMockInitialValues({
        'printer_last_mac': 'AA:BB:CC:DD:EE:FF',
        'printer_last_name': 'RPP02',
      });
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k1',
          name: 'RPP02',
          mac: 'AA:BB:CC:DD:EE:FF',
          jenis: 'kasir',
        ),
      );
      await ps.removePrinter('k1');

      // Registry kosong → printReceiptBytes jatuh ke jalur legacy →
      // tryAutoReconnect(last-MAC) → struk tetap keluar dari printer yang
      // baru saja user hapus.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('printer_last_mac'), isNull);
      expect(prefs.getString('printer_last_name'), isNull);
    });

    test('menghapus printer lain tidak mengusik last-MAC', () async {
      SharedPreferences.setMockInitialValues({
        'printer_last_mac': 'AA:BB:CC:DD:EE:01',
        'printer_last_name': 'Kasir',
      });
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'k1', name: 'Kasir', mac: 'AA:BB:CC:DD:EE:01'),
      );
      await ps.savePrinter(
        const SavedPrinter(id: 'd1', name: 'Dapur', mac: 'AA:BB:CC:DD:EE:02'),
      );
      await ps.removePrinter('d1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('printer_last_mac'), 'AA:BB:CC:DD:EE:01');
    });
  });

  group('isValidIpv4 — typo IP ketahuan saat mengetik, bukan saat cetak', () {
    test('alamat sah diterima', () {
      for (final ip in [
        '192.168.1.50',
        '10.0.0.1',
        '0.0.0.0',
        '255.255.255.255',
      ]) {
        expect(isValidIpv4(ip), true, reason: ip);
      }
    });

    test('alamat cacat ditolak', () {
      for (final ip in [
        '192.168.1.999', // oktet > 255 — dulu lolos
        '192.168.1', // kurang oktet — dulu lolos
        '192.168.1.50.1',
        '192.168.1.',
        'printer.local', // hostname belum didukung _writeBytesLan
        '192.168.01.5', // nol di depan, ambigu oktal
        '',
        ' ',
      ]) {
        expect(isValidIpv4(ip), false, reason: ip);
      }
    });
  });
}

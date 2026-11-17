import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time420s/shared/services/printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SavedPrinter serialisasi (semua jenis & koneksi)', () {
    test('round-trip mempertahankan semua field', () {
      const p = SavedPrinter(
        id: 'p1',
        name: 'Printer Dapur',
        mac: 'AA:BB:CC:DD:EE:FF',
        type: 'bt',
        host: '',
        port: 9100,
        paper: '80',
        copies: 3,
        jenis: 'dapur',
        driver: 'generic1',
        terpusat: true,
        autoOrder: true,
        autoQrOrder: true,
        autoBayar: false,
        autoVoid: true,
        categories: ['cat-a', 'cat-b'],
        printMode: 'pisah',
        enabled: false,
        dapurEnabled: true, // multi-peran: isKitchen kini mengikuti peran Dapur
      );
      final back = SavedPrinter.fromMap(p.toMap());
      expect(back.id, 'p1');
      expect(back.name, 'Printer Dapur');
      expect(back.mac, 'AA:BB:CC:DD:EE:FF');
      expect(back.type, 'bt');
      expect(back.paper, '80');
      expect(back.copies, 3);
      expect(back.jenis, 'dapur');
      expect(back.terpusat, true);
      expect(back.autoOrder, true);
      expect(back.autoQrOrder, true);
      expect(back.autoBayar, false);
      expect(back.autoVoid, true);
      expect(back.categories, ['cat-a', 'cat-b']);
      expect(back.printMode, 'pisah');
      expect(back.enabled, false);
      expect(back.isKitchen, true);
    });

    test('default value aman saat map tidak lengkap (legacy)', () {
      final back = SavedPrinter.fromMap({'id': 'x', 'name': 'Lama'});
      expect(back.type, 'bt');
      expect(back.paper, '58');
      expect(back.copies, 1);
      expect(back.jenis, 'kasir');
      expect(back.enabled, true); // default aktif
      expect(back.printMode, 'gabung');
      expect(back.categories, isEmpty);
      expect(back.autoQrOrder, false);
    });

    test('printer LAN: host/port & isLan benar', () {
      const p = SavedPrinter(
        id: 'l1',
        name: 'Bar LAN',
        type: 'lan',
        host: '192.168.1.50',
        port: 9100,
        jenis: 'dapur',
      );
      final back = SavedPrinter.fromMap(p.toMap());
      expect(back.isLan, true);
      expect(back.host, '192.168.1.50');
      expect(back.port, 9100);
    });
  });

  group('Registry PrinterService (semua jenis printer)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('save & list semua 6 jenis', () async {
      final ps = PrinterService();
      const jenisAll = [
        'kasir',
        'dapur',
        'label',
        'alamat',
        'terpusat',
        'scanner',
      ];
      for (var i = 0; i < jenisAll.length; i++) {
        await ps.savePrinter(
          SavedPrinter(id: 'id$i', name: 'P$i', mac: 'M$i', jenis: jenisAll[i]),
        );
      }
      final list = await ps.listPrinters();
      expect(list.length, 6);
      for (final j in jenisAll) {
        expect(
          (await ps.printersByJenis(j)).length,
          1,
          reason: 'jenis $j harus ada 1',
        );
      }
    });

    test('printer kasir pertama otomatis jadi default', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'k1', name: 'Kasir', jenis: 'kasir'),
      );
      expect(await ps.defaultPrinterId(), 'k1');
    });

    test('default printer dapat dipindah secara manual', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k1',
          name: 'Kasir 1',
          mac: 'AA:01',
          jenis: 'kasir',
        ),
      );
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k2',
          name: 'Kasir 2',
          mac: 'AA:02',
          jenis: 'kasir',
        ),
      );
      await ps.setDefaultPrinter('k2');
      expect(await ps.defaultPrinterId(), 'k2');
    });

    test('job cetak gagal tersimpan untuk retry manual', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'l1',
          name: 'LAN gagal',
          type: 'lan',
          host: '127.0.0.1',
          port: 1,
          jenis: 'kasir',
        ),
      );
      expect(await ps.printReceiptBytes(const [1, 2, 3]), PrintOutcome.failed);
      final jobs = await ps.pendingPrintJobs();
      expect(jobs, hasLength(1));
      expect(jobs.single.label, 'Struk');
      await ps.discardPrintJob(jobs.single.id);
      expect(await ps.pendingPrintJobs(), isEmpty);
    });

    test('jumlah salinan tersisa tersimpan dalam antrean', () {
      final now = DateTime(2026, 10, 2, 12);
      final job = PrintJob(
        id: 'job-1',
        printerId: 'dapur-1',
        label: 'Tiket dapur',
        bytes: const [1, 2, 3],
        createdAt: now,
        copies: 3,
      );

      final restored = PrintJob.fromMap(job.toMap());
      expect(restored.copies, 3);
      expect(restored.bytes, [1, 2, 3]);
    });

    test('metadata klaim tiket dapur ikut tersimpan dalam antrean', () {
      final job = PrintJob(
        id: 'kitchen-job',
        printerId: 'dapur-1',
        label: 'Tiket dapur',
        bytes: const [1, 2, 3],
        createdAt: DateTime(2026, 10, 2, 12),
        kitchenOrderId: 'order-1',
        kitchenDeviceId: 'device-1',
        awaitingServerAck: true,
      );

      final restored = PrintJob.fromMap(job.toMap());
      expect(restored.isKitchenJob, true);
      expect(restored.kitchenOrderId, 'order-1');
      expect(restored.kitchenDeviceId, 'device-1');
      expect(restored.awaitingServerAck, true);
    });

    test(
      'ack server tanpa byte cetak tetap bertahan setelah restart',
      () async {
        final ps = PrinterService();
        await ps.enqueueKitchenAcknowledgement(
          orderId: 'order-ack',
          deviceId: 'device-ack',
        );

        final jobs = await ps.pendingPrintJobs();
        expect(jobs, hasLength(1));
        expect(jobs.single.bytes, isEmpty);
        expect(jobs.single.awaitingServerAck, true);
        expect(jobs.single.kitchenOrderId, 'order-ack');
      },
    );

    test(
      'update field printer (kertas, copies, autoprint, kategori)',
      () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(id: 'd1', name: 'Dapur', jenis: 'dapur'),
        );
        await ps.updatePrinter(
          'd1',
          paper: '80',
          copies: 2,
          autoOrder: true,
          autoQrOrder: true,
          categories: ['c1'],
          printMode: 'pisah',
          headerLabel: 'DAPUR PUMPIS',
        );
        final p = (await ps.listPrinters()).firstWhere((e) => e.id == 'd1');
        expect(p.paper, '80');
        expect(p.copies, 2);
        expect(p.autoOrder, true);
        expect(p.autoQrOrder, true);
        expect(p.categories, ['c1']);
        expect(p.printMode, 'pisah');
        expect(p.headerLabel, 'DAPUR PUMPIS');
      },
    );

    // Peta stasiun dihapus (yatim: tak ada UI yang menugaskan printer ke
    // stasiun; perutean dapur memakai kategori). Yang tersisa diuji: default
    // tidak menggantung setelah printer-nya hilang.
    test('remove printer membersihkan default', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'k1', name: 'Kasir', jenis: 'kasir'),
      );
      await ps.removePrinter('k1');
      expect((await ps.listPrinters()), isEmpty);
      expect(await ps.defaultPrinterId(), isNull);
    });

    test('default pindah ke printer tersisa, bukan menggantung', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k1',
          name: 'Kasir',
          mac: 'AA:01',
          jenis: 'kasir',
        ),
      );
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k2',
          name: 'Cadangan',
          mac: 'AA:02',
          jenis: 'kasir',
        ),
      );
      expect(await ps.defaultPrinterId(), 'k1');
      await ps.removePrinter('k1');
      expect(await ps.defaultPrinterId(), 'k2');
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time420s/shared/models/menu_item.dart';
import 'package:time420s/shared/models/order.dart';
import 'package:time420s/shared/services/kitchen_print.dart';
import 'package:time420s/shared/services/kitchen_ticket_builder.dart';
import 'package:time420s/shared/services/printer_service.dart';

MenuItem _menu(String id, {String? catId}) => MenuItem(
  id: id,
  outletId: 'o1',
  categoryId: catId,
  name: 'Item $id',
  price: 10000,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  sortOrder: 0,
);

OrderItem _item(String id, {String? catId, bool noMenu = false}) => OrderItem(
  id: id,
  orderId: 'ord1',
  menuItemId: 'm-$id',
  quantity: 1,
  unitPrice: 10000,
  subtotal: 10000,
  menuItem: noMenu ? null : _menu('m-$id', catId: catId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('physical send recorder — idempotensi lifecycle', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PrinterService().setPhysicalSenderForTest(null);
    });

    tearDown(() => PrinterService().setPhysicalSenderForTest(null));

    test('reprint manual mengirim tepat sekali ke satu target', () async {
      final printer = PrinterService();
      await printer.savePrinter(
        const SavedPrinter(
          id: 'dapur-a',
          name: 'RPP02N',
          jenis: 'dapur',
          dapurEnabled: true,
          copies: 4,
          host: '192.168.1.50',
        ),
      );
      final targets = <String>[];
      printer.setPhysicalSenderForTest((target, _) async {
        targets.add(target.id);
        return true;
      });

      final sent = await printer.printToPrinterId(
        'dapur-a',
        const [1, 2, 3],
        copiesOverride: 1,
        enqueueOnFailure: false,
        requestId: 'reprint-001',
        intent: 'kitchen_reprint',
      );

      expect(sent, true);
      expect(targets, ['dapur-a']);
      expect(await printer.pendingPrintJobs(), isEmpty);
    });

    test('job sukses dihapus dan tidak diputar ulang', () async {
      final printer = PrinterService();
      await printer.savePrinter(
        const SavedPrinter(
          id: 'dapur-a',
          name: 'RPP02N',
          jenis: 'dapur',
          dapurEnabled: true,
          host: '192.168.1.50',
        ),
      );
      var sends = 0;
      var succeeds = false;
      printer.setPhysicalSenderForTest((_, _) async {
        sends++;
        return succeeds;
      });

      expect(
        await printer.printToPrinterId(
          'dapur-a',
          const [9],
          requestId: 'initial-001',
          intent: 'kitchen_initial',
        ),
        false,
      );
      final queued = await printer.pendingPrintJobs();
      expect(queued, hasLength(1));
      expect(queued.single.requestId, 'initial-001');

      succeeds = true;
      expect(await printer.retryPrintJob(queued.single.id), true);
      expect(await printer.pendingPrintJobs(), isEmpty);
      expect(sends, 2);

      await printer.retryAllPrintJobs();
      expect(sends, 2, reason: 'job sukses tidak boleh replay lagi');
    });

    test('kegagalan reprint eksplisit tidak masuk retry queue', () async {
      final printer = PrinterService();
      await printer.savePrinter(
        const SavedPrinter(
          id: 'dapur-a',
          name: 'RPP02N',
          jenis: 'dapur',
          dapurEnabled: true,
          host: '192.168.1.50',
        ),
      );
      var sends = 0;
      printer.setPhysicalSenderForTest((_, _) async {
        sends++;
        return false;
      });

      await printer.printToPrinterId(
        'dapur-a',
        const [7],
        copiesOverride: 1,
        enqueueOnFailure: false,
        requestId: 'reprint-failed',
        intent: 'kitchen_reprint',
      );

      expect(await printer.pendingPrintJobs(), isEmpty);
      await printer.retryAllPrintJobs();
      expect(
        sends,
        1,
        reason: 'reconnect/retry processing tidak boleh memutar reprint gagal',
      );
    });

    test(
      'job biasa legacy dibersihkan agar tidak replay setelah upgrade',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'print_jobs_json',
          jsonEncode([
            {
              'id': 'job-lama',
              'printerId': 'dapur-a',
              'label': 'Cetak lama',
              'bytes': base64Encode(const [1, 2, 3]),
              'createdAt': DateTime(2026).toIso8601String(),
            },
          ]),
        );

        expect(await PrinterService().pendingPrintJobs(), isEmpty);
        expect(jsonDecode(prefs.getString('print_jobs_json')!), isEmpty);
      },
    );
  });

  test('reprint manual mengikuti mode pisah per kategori', () {
    const printer = SavedPrinter(
      id: 'dapur-a',
      name: 'RPP02N',
      jenis: 'dapur',
      dapurEnabled: true,
      printMode: 'pisah',
      categories: ['cat-a', 'cat-b'],
    );
    final batches = manualKitchenReprintBatch(
      printer: printer,
      items: [
        _item('a', catId: 'cat-a'),
        _item('b', catId: 'cat-b'),
      ],
      categoryNames: const {'cat-a': 'PUMPIS', 'cat-b': 'SNACK'},
    );

    expect(batches, hasLength(2));
    expect(batches.map((batch) => batch.targetName), ['PUMPIS', 'SNACK']);
    expect(batches.map((batch) => batch.items.single.id), ['a', 'b']);
  });

  group('SavedPrinter — headerLabel & copyWith jenis (audit printer)', () {
    test('headerLabel ikut round-trip toMap/fromMap', () {
      const p = SavedPrinter(
        id: 'p1',
        name: 'RPP02N',
        jenis: 'dapur',
        headerLabel: 'Dapur - Bar',
      );
      final back = SavedPrinter.fromMap(p.toMap());
      expect(back.headerLabel, 'Dapur - Bar');
    });

    test('map legacy tanpa headerLabel → default kosong', () {
      final back = SavedPrinter.fromMap({'id': 'x', 'name': 'Lama'});
      expect(back.headerLabel, '');
    });

    test('copyWith(jenis:) mengganti peran; tanpa arg → jenis tetap', () {
      const p = SavedPrinter(id: 'p1', name: 'P', jenis: 'kasir');
      expect(p.copyWith(jenis: 'dapur').jenis, 'dapur');
      expect(
        p.copyWith(copies: 2).jenis,
        'kasir',
      ); // regresi: dulu selalu reset
      expect(
        p.copyWith(headerLabel: 'Dapur - Kebab').headerLabel,
        'Dapur - Kebab',
      );
    });

    test('stationId ikut round-trip agar binding outlet tidak hilang', () {
      const p = SavedPrinter(
        id: 'p1',
        name: 'Bar',
        jenis: 'dapur',
        stationId: 'bar-station',
      );
      expect(SavedPrinter.fromMap(p.toMap()).stationId, 'bar-station');
    });

    test('beberapa stationIds ikut round-trip tanpa duplikat', () {
      const p = SavedPrinter(
        id: 'p1',
        name: 'Printer Bersama',
        jenis: 'dapur',
        stationIds: ['bar', 'kebab', 'kopi', 'bar'],
      );
      final back = SavedPrinter.fromMap(p.toMap());
      expect(back.effectiveStationIds, ['bar', 'kebab', 'kopi']);
    });

    test('data lama stationId dibaca sebagai satu pilihan stasiun', () {
      final back = SavedPrinter.fromMap({
        'id': 'legacy',
        'name': 'Printer Lama',
        'stationId': 'bar',
      });
      expect(back.effectiveStationIds, ['bar']);
    });

    test('migrasi legacy: peran per-tab di-derive dari jenis+enabled', () {
      final dapurLama = SavedPrinter.fromMap({
        'id': 'a',
        'name': 'D',
        'jenis': 'dapur',
        'copies': 3,
      });
      expect(dapurLama.dapurEnabled, true);
      expect(dapurLama.strukEnabled, false);
      expect(dapurLama.copies, 3); // salinan tiket dapur memakai `copies`

      final kasirLama = SavedPrinter.fromMap({
        'id': 'b',
        'name': 'K',
        'jenis': 'kasir',
      });
      expect(kasirLama.strukEnabled, true);
      expect(kasirLama.dapurEnabled, false);
      expect(kasirLama.strukAutoBayar, true);

      final mati = SavedPrinter.fromMap({
        'id': 'c',
        'name': 'X',
        'jenis': 'kasir',
        'enabled': false,
      });
      expect(mati.strukEnabled, false);
      expect(mati.dapurEnabled, false);
    });

    test('multi-peran: struk + dapur bisa aktif bersamaan (round-trip)', () {
      const p = SavedPrinter(
        id: 'p1',
        name: 'P',
        strukEnabled: true,
        dapurEnabled: true,
        strukAutoOrder: false,
        strukAutoBayar: false,
        autoQrOrder: true,
        copies: 2,
      );
      final back = SavedPrinter.fromMap(p.toMap());
      expect(back.strukEnabled, true);
      expect(back.dapurEnabled, true);
      expect(back.strukAutoOrder, false);
      expect(back.strukAutoBayar, false);
      expect(back.autoQrOrder, true);
      expect(back.copies, 2);
      expect(back.isKitchen, true);
    });
  });

  group('printerForReceipt — pilih printer struk yang layak', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('default aktif & bukan dapur → dipakai', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'k1', name: 'Kasir', jenis: 'kasir'),
      );
      expect((await ps.printerForReceipt())?.id, 'k1');
    });

    test(
      'default dimatikan peran Struk-nya → fallback ke printer struk lain',
      () async {
        final ps = PrinterService();
        await ps.savePrinter(
          const SavedPrinter(
            id: 'k1',
            name: 'Kasir',
            jenis: 'kasir',
            strukEnabled: false,
          ),
        );
        await ps.savePrinter(
          const SavedPrinter(id: 'k2', name: 'Kasir 2', jenis: 'kasir'),
        );
        expect(await ps.defaultPrinterId(), 'k1'); // default tetap k1
        expect((await ps.printerForReceipt())?.id, 'k2'); // tapi struk ke k2
      },
    );

    test('printer dapur-saja → struk tidak nyasar ke printer dapur', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(id: 'k1', name: 'P', jenis: 'kasir'),
      );
      // Peran Struk dimatikan, Dapur dinyalakan (via tab).
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k1',
          name: 'P',
          jenis: 'dapur',
          strukEnabled: false,
          dapurEnabled: true,
        ),
      );
      expect(await ps.printerForReceipt(), isNull);
    });

    test('multi-peran: printer sama bisa struk sekaligus dapur', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'p1',
          name: 'Serbaguna',
          jenis: 'kasir',
          strukEnabled: true,
          dapurEnabled: true,
        ),
      );
      expect((await ps.printerForReceipt())?.id, 'p1');
      expect((await ps.kitchenPrinters()).map((p) => p.id), ['p1']);
    });

    test('semua peran Struk nonaktif → null (struk tidak dicetak)', () async {
      final ps = PrinterService();
      await ps.savePrinter(
        const SavedPrinter(
          id: 'k1',
          name: 'Kasir',
          jenis: 'kasir',
          strukEnabled: false,
        ),
      );
      expect(await ps.printerForReceipt(), isNull);
    });
  });

  group('kitchenPrinterMatches — trigger autoprint dapur', () {
    const base = SavedPrinter(
      id: 'd1',
      name: 'Dapur',
      jenis: 'dapur',
      dapurEnabled: true,
      autoOrder: true,
      autoQrOrder: false,
      autoBayar: false,
      autoVoid: true,
    );

    test('peran Dapur mati → tidak pernah cocok (termasuk manual)', () {
      final off = base.copyWith(dapurEnabled: false);
      expect(kitchenPrinterMatches(off, null), false);
      expect(kitchenPrinterMatches(off, KitchenTrigger.order), false);
    });

    test('trigger null (manual/reprint) selalu cocok bila aktif', () {
      expect(kitchenPrinterMatches(base, null), true);
    });

    test('trigger mengikuti toggle per printer', () {
      expect(kitchenPrinterMatches(base, KitchenTrigger.order), true);
      expect(kitchenPrinterMatches(base, KitchenTrigger.qrOrder), false);
      expect(kitchenPrinterMatches(base, KitchenTrigger.bayar), false);
      expect(kitchenPrinterMatches(base, KitchenTrigger.voidOrder), true);
    });

    test('pesanan QR hanya cocok pada printer yang toggle QR-nya aktif', () {
      final qrPrinter = base.copyWith(autoOrder: false, autoQrOrder: true);
      expect(kitchenPrinterMatches(qrPrinter, KitchenTrigger.order), false);
      expect(kitchenPrinterMatches(qrPrinter, KitchenTrigger.qrOrder), true);
    });
  });

  test('manual reprint hanya memilih printer target, bukan broadcast', () {
    const printers = [
      SavedPrinter(id: 'cashier', name: 'Kasir', strukEnabled: true),
      SavedPrinter(
        id: 'dapur-a',
        name: 'Dapur A',
        strukEnabled: false,
        dapurEnabled: true,
      ),
      SavedPrinter(
        id: 'dapur-b',
        name: 'Dapur B',
        strukEnabled: false,
        dapurEnabled: true,
      ),
    ];

    expect(
      kitchenPrintersForIntent(
        printers,
        trigger: null,
        targetPrinterId: 'dapur-a',
      ).map((printer) => printer.id),
      ['dapur-a'],
    );
  });

  group('kitchenItemsForPrinter — filter kategori', () {
    test('kategori kosong = semua item', () {
      const p = SavedPrinter(id: 'd1', name: 'D', jenis: 'dapur');
      final items = [_item('a', catId: 'c1'), _item('b', catId: 'c2')];
      expect(kitchenItemsForPrinter(p, items).length, 2);
    });

    test('hanya item kategori terpilih + item tanpa kategori ikut', () {
      const p = SavedPrinter(
        id: 'd1',
        name: 'D',
        jenis: 'dapur',
        categories: ['c1'],
      );
      final items = [
        _item('a', catId: 'c1'), // cocok
        _item('b', catId: 'c2'), // bukan kategori printer ini
        _item('c', noMenu: true), // tanpa menu → tetap ikut (jangan hilang)
        _item('d'), // categoryId null → tetap ikut
      ];
      final out = kitchenItemsForPrinter(p, items).map((e) => e.id).toList();
      expect(out, ['a', 'c', 'd']);
    });

    test('binding stasiun outlet mengalahkan mapping kategori lokal', () {
      const p = SavedPrinter(
        id: 'd1',
        name: 'Bar',
        jenis: 'dapur',
        stationId: 'bar',
        categories: ['c1'],
      );
      final config = PrintStationConfig.fromSettings({
        'print_stations': [
          {'id': 'bar', 'name': 'Bar'},
          {'id': 'kitchen', 'name': 'Dapur'},
        ],
        'print_category_station': {'c2': 'bar', 'c3': 'kitchen'},
      });
      final out = kitchenItemsForPrinterWithStations(p, [
        _item('a', catId: 'c1'),
        _item('b', catId: 'c2'),
      ], stationConfig: config).map((e) => e.id).toList();
      expect(out, ['b']);
    });

    test('beberapa stasiun mengambil gabungan kategori yang dilayani', () {
      const p = SavedPrinter(
        id: 'd1',
        name: 'Printer Bersama',
        jenis: 'dapur',
        stationIds: ['bar', 'kopi'],
        categories: ['kategori-lokal-diabaikan'],
      );
      final config = PrintStationConfig.fromSettings({
        'print_stations': [
          {'id': 'bar', 'name': 'Bar'},
          {'id': 'kebab', 'name': 'Kebab'},
          {'id': 'kopi', 'name': 'Kopi'},
        ],
        'print_category_station': {
          'c-bar': 'bar',
          'c-kebab': 'kebab',
          'c-kopi': 'kopi',
        },
      });

      final out = kitchenItemsForPrinterWithStations(p, [
        _item('bar', catId: 'c-bar'),
        _item('kebab', catId: 'c-kebab'),
        _item('kopi', catId: 'c-kopi'),
      ], stationConfig: config).map((item) => item.id).toList();

      expect(out, ['bar', 'kopi']);
    });
  });

  group('kitchenStationBatchesForPrinter — satu printer banyak stasiun', () {
    test('membuat tiket terpisah mengikuti urutan stasiun Owner Panel', () {
      const printer = SavedPrinter(
        id: 'd1',
        name: 'Printer Bersama',
        dapurEnabled: true,
        stationIds: ['kopi', 'bar', 'kebab'],
      );
      final config = PrintStationConfig.fromSettings({
        'print_stations': [
          {'id': 'bar', 'name': 'Bar'},
          {'id': 'kebab', 'name': 'Kebab'},
          {'id': 'kopi', 'name': 'Kopi'},
        ],
        'print_category_station': {
          'c-bar': 'bar',
          'c-kebab': 'kebab',
          'c-kopi': 'kopi',
        },
      });

      final batches = kitchenStationBatchesForPrinter(printer, [
        _item('kopi', catId: 'c-kopi'),
        _item('bar', catId: 'c-bar'),
        _item('kebab', catId: 'c-kebab'),
      ], config);

      expect(batches.map((batch) => batch.station.name), [
        'Bar',
        'Kebab',
        'Kopi',
      ]);
      expect(batches[0].items.single.id, 'bar');
      expect(batches[1].items.single.id, 'kebab');
      expect(batches[2].items.single.id, 'kopi');
    });
  });

  group('kitchenTicketBatchesForPrinter — prioritas mode cetak', () {
    final config = PrintStationConfig.fromSettings({
      'print_stations': [
        {'id': 'bersama', 'name': 'Dapur Bersama'},
      ],
      'print_category_station': {
        'c-non-coffee': 'bersama',
        'c-kebab': 'bersama',
        'c-burger': 'bersama',
        'c-coffee': 'bersama',
      },
    });
    final items = [
      _item('air-mineral', catId: 'c-non-coffee'),
      _item('matcha', catId: 'c-non-coffee'),
      _item('kebab', catId: 'c-kebab'),
      _item('burger', catId: 'c-burger'),
      _item('vanilla', catId: 'c-coffee'),
    ];
    final categoryNames = <String, String>{
      'c-non-coffee': 'NON COFFEE',
      'c-kebab': 'KEBAB',
      'c-burger': 'BURGER',
      'c-coffee': 'SWEET & FLAVOUR COFFEE',
    };

    test('Pisah tetap membuat satu tiket per kategori pada station sama', () {
      const printer = SavedPrinter(
        id: 'd1',
        name: 'RPP02N',
        dapurEnabled: true,
        printMode: 'pisah',
        stationIds: ['bersama'],
      );

      final batches = kitchenTicketBatchesForPrinter(
        printer: printer,
        items: items,
        categoryNames: categoryNames,
        stationConfig: config,
      );

      expect(batches.map((batch) => batch.targetName), [
        'NON COFFEE',
        'KEBAB',
        'BURGER',
        'SWEET & FLAVOUR COFFEE',
      ]);
      expect(batches[0].items.map((item) => item.id), [
        'air-mineral',
        'matcha',
      ]);
      expect(batches[1].items.single.id, 'kebab');
      expect(batches[2].items.single.id, 'burger');
      expect(batches[3].items.single.id, 'vanilla');
    });

    test('Gabung membuat tepat satu tiket meski printer punya station', () {
      const printer = SavedPrinter(
        id: 'd1',
        name: 'RPP02N',
        dapurEnabled: true,
        printMode: 'gabung',
        stationIds: ['bersama'],
      );

      final batches = kitchenTicketBatchesForPrinter(
        printer: printer,
        items: items,
        categoryNames: categoryNames,
        stationConfig: config,
      );

      expect(batches, hasLength(1));
      expect(batches.single.targetName, 'RPP02N');
      expect(batches.single.items, hasLength(5));
    });

    test('Gabung memakai label printer tanpa label station berulang', () {
      const printer = SavedPrinter(
        id: 'd1',
        name: 'RPP02N',
        headerLabel: 'DAPUR UTAMA',
        dapurEnabled: true,
        printMode: 'gabung',
        stationIds: ['bersama'],
      );

      final batches = kitchenTicketBatchesForPrinter(
        printer: printer,
        items: items,
        categoryNames: categoryNames,
        stationConfig: config,
      );

      expect(batches, hasLength(1));
      expect(batches.single.targetName, 'DAPUR UTAMA');
      expect(batches.single.items, hasLength(5));
    });
  });

  test('item makanan yang belum terpetakan masuk fallback dapur', () {
    final minuman = _item('minuman', catId: 'c-minuman');
    final makanan = _item('makanan', catId: 'c-makanan');

    final fallback = unroutedKitchenItems([minuman, makanan], {'minuman'});

    expect(fallback.map((item) => item.id), ['makanan']);
  });

  test(
    'kategori sengaja dikecualikan berbeda dari kategori belum dipetakan',
    () {
      final config = PrintStationConfig.fromSettings({
        'print_stations': [
          {'id': 'dapur', 'name': 'Dapur'},
        ],
        'print_category_station': <String, String>{},
        'print_excluded_categories': ['c-non-dapur'],
      });

      expect(config.isEnabled, true);
      expect(config.excludedCategoryIds, contains('c-non-dapur'));
      expect(config.excludedCategoryIds, isNot(contains('c-makanan-baru')));
    },
  );
}

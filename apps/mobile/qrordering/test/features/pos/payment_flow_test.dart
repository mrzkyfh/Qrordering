import 'dart:convert';
import 'dart:io';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qrordering/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qrordering/features/pos/domain/entities/cart_item.dart';
import 'package:qrordering/features/pos/domain/entities/selected_extra.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';
import 'package:qrordering/features/pos/presentation/bloc/pos_bloc.dart';
import 'package:qrordering/features/pos/presentation/pages/payment_page.dart';
import 'package:qrordering/features/settings/data/app_settings.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/profile.dart';
import 'package:qrordering/shared/services/offline_queue_service.dart';
import 'package:qrordering/shared/services/connectivity_service.dart';
import 'package:qrordering/shared/services/staff_authorization_lease.dart';

/// Regression: alur "cetak dulu, sinkron belakangan".
///
/// Menekan Bayar HARUS menitipkan transaksi lengkap ke antrean lokal sebelum
/// apa pun dikirim ke server. Yang dijaga ketat di sini adalah kelengkapan
/// payload — sekali sebuah field lolos dari payload, replay tidak akan pernah
/// menuliskannya dan datanya hilang TANPA error apa pun: kas tak masuk laci,
/// poin member hangus, promo tak pernah diklaim. Persis bug yang dulu diam-diam
/// menggerogoti transaksi offline.
class MockPosBloc extends MockBloc<PosEvent, PosState> implements PosBloc {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

const _outletId = 'outlet-1';
const _kasirId = 'kasir-1';

Profile _profile() => Profile(
  id: _kasirId,
  outletId: _outletId,
  role: UserRole.kasir,
  fullName: 'Andi',
  isActive: true,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

/// Keranjang: 2 × Kopi 10.000 + extra Boba 2.000 → subtotal 24.000.
PosState _stateWithCart({
  String? loyaltyMemberId,
  int redeemedPoints = 0,
  double loyaltyDiscount = 0,
  String? promoId,
  String? voucherId,
}) {
  const menu = MenuItem(
    id: 'menu-1',
    outletId: _outletId,
    name: 'Kopi',
    price: 10000,
    isAvailable: true,
    isActive: true,
    isFeatured: false,
    sortOrder: 0,
  );
  return PosState(
    cart: const [
      CartItem(
        id: 'cart-1',
        menuItem: menu,
        quantity: 2,
        notes: 'less sugar',
        selectedExtras: [
          SelectedExtra(
            menuExtraId: 'ex-1',
            menuExtraOptionId: 'exo-1',
            extraName: 'Topping',
            optionName: 'Boba',
            price: 2000,
          ),
        ],
      ),
    ],
    orderType: OrderType.dineIn,
    tableId: 'table-9',
    tableNumber: '9',
    customerName: 'Budi',
    loyaltyMemberId: loyaltyMemberId,
    loyaltyDiscount: loyaltyDiscount,
    redeemedPoints: redeemedPoints,
    promoId: promoId,
    voucherId: voucherId,
  );
}

void main() {
  late Directory tmp;
  late MockPosBloc posBloc;
  late MockAuthBloc authBloc;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('payment_flow_test');
    Hive.init(tmp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await Hive.openBox(OfflineQueueService.boxName);
    await Hive.openBox(OfflineQueueService.deadBoxName);
    await Hive.openBox(AppSettings.boxName);
    for (final b in [
      PosDatasource.menuCacheBoxName,
      OfflineQueueService.boxName,
      OfflineQueueService.deadBoxName,
      AppSettings.boxName,
    ]) {
      await Hive.box(b).clear();
    }
    await StaffAuthorizationLease.grant(_kasirId);
    // Till kasir sudah ter-cache (dihangatkan saat halaman bayar dibuka) →
    // resolusi till berjalan tanpa jaringan, seperti di perangkat sungguhan.
    final cachedShiftStart = DateTime.now().toUtc().subtract(
      const Duration(hours: 1),
    );
    final cachedShiftVerified = cachedShiftStart.add(
      const Duration(seconds: 1),
    );
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'open_shifts_$_outletId',
      jsonEncode([
        {'id': 'shift-lain', 'kasir_id': 'kasir-9', 'kasir_name': 'Owner'},
        {
          'id': 'shift-andi',
          'kasir_id': _kasirId,
          'kasir_name': 'Andi',
          'start_time': cachedShiftStart.toIso8601String(),
          'verified_at': cachedShiftVerified.toIso8601String(),
        },
      ]),
    );
    OfflineQueueService.instance.init();
    ConnectivityService.instance.online.value = false;

    posBloc = MockPosBloc();
    authBloc = MockAuthBloc();
    when(
      () => authBloc.state,
    ).thenReturn(AuthAuthenticated(profile: _profile()));
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  Widget harness() => MaterialApp(
    home: MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<PosBloc>.value(value: posBloc),
      ],
      child: const PaymentPage(),
    ),
  );

  /// Surface uji dibuat tinggi supaya numpad & tombol Bayar ikut ter-layout;
  /// pada 800×600 default, tombol Bayar jatuh di luar viewport dan tap meleset.
  Future<void> pumpPayment(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness());
    await tester.pump();
  }

  /// Jalankan sampai transaksi masuk antrean, lalu kembalikan payloadnya.
  ///
  /// runAsync wajib: alur bayar menulis ke Hive (I/O file sungguhan), dan di
  /// zona fake-async milik testWidgets future I/O tidak pernah selesai — tanpa
  /// ini `enqueue` menggantung selamanya dan antrean tampak kosong.
  Future<Map<String, dynamic>> tapBayar(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.textContaining('Bayar '));
      await Future.delayed(const Duration(milliseconds: 400));
    });
    final all = OfflineQueueService.instance.all();
    expect(all, hasLength(1), reason: 'transaksi wajib masuk antrean lokal');
    return all.first.value;
  }

  testWidgets('tunai: payload lengkap & kas nempel ke till kasir sendiri', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await pumpPayment(tester);

    // Terima Rp 25.000 untuk total Rp 24.000 (tombol nominal cepat).
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 25.000'));
    await tester.pump();

    final p = await tapBayar(tester);

    expect(p['kind'], 'paid');
    expect(
      p['shiftId'],
      'shift-andi',
      reason: 'kas tunai harus masuk laci kasir sendiri, bukan till owner',
    );
    expect(p['outletId'], _outletId);
    expect(p['createdBy'], _kasirId);
    expect(p['paymentMethod'], 'cash');
    expect(p['total'], 24000);
    expect(p['subtotal'], 24000);
    expect(p['amount'], 24000);
    expect(p['tableId'], 'table-9');
    expect(p['customerName'], 'Budi');
    expect(p['orderType'], 'dine_in');
    expect(p['clientOrderId'], isNotEmpty);
    expect(p['idempotencyKey'], isNotEmpty);
    // Waktu transaksi dikirim sebagai instan UTC (lihat catatan timestamptz).
    expect(DateTime.parse(p['createdAt'] as String).isUtc, isTrue);
    expect(p['shiftSource'], 'cache_offline');
    expect(DateTime.parse(p['shiftStartedAt'] as String).isUtc, isTrue);
    expect(DateTime.parse(p['shiftVerifiedAt'] as String).isUtc, isTrue);
  });

  testWidgets('non-tunai tetap membawa shift kasir (laporan per-shift utuh)', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await pumpPayment(tester);

    await tester.tap(find.text('QRIS'));
    await tester.pump();

    final p = await tapBayar(tester);

    expect(p['paymentMethod'], 'qris');
    expect(
      p['shiftId'],
      'shift-andi',
      reason:
          'createOrder lama selalu meresolusi shift untuk metode APA PUN '
          '— non-tunai tidak boleh kehilangan atribusi shift',
    );
  });

  testWidgets('loyalty & promo ikut ke antrean (dulu hilang diam-diam)', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(
      _stateWithCart(
        loyaltyMemberId: 'member-7',
        redeemedPoints: 50,
        loyaltyDiscount: 5000,
        promoId: 'promo-3',
        voucherId: 'voucher-2',
      ),
    );
    await pumpPayment(tester);

    // Total = 24.000 − 5.000 diskon poin = 19.000.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 20.000'));
    await tester.pump();

    final p = await tapBayar(tester);

    expect(p['loyaltyMemberId'], 'member-7');
    expect(p['redeemedPoints'], 50);
    expect(p['loyaltyDiscount'], 5000);
    expect(p['promoId'], 'promo-3');
    expect(p['voucherId'], 'voucher-2');
    expect(p['total'], 19000, reason: 'diskon poin harus terpotong dari total');
  });

  testWidgets('item, catatan, & extra utuh melewati serialisasi Hive', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await pumpPayment(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 25.000'));
    await tester.pump();

    final p = await tapBayar(tester);

    final items = (p['items'] as List).cast<Map>();
    expect(items, hasLength(1));
    expect(items.first['menuItemId'], 'menu-1');
    expect(items.first['quantity'], 2);
    expect(items.first['unitPrice'], 12000, reason: 'harga + extra Boba');
    expect(items.first['subtotal'], 24000);
    expect(items.first['notes'], 'less sugar');

    final extras = (items.first['extras'] as List).cast<Map>();
    expect(extras, hasLength(1));
    expect(extras.first['menuExtraOptionId'], 'exo-1');
    expect(extras.first['optionName'], 'Boba');
    expect(extras.first['price'], 2000);
  });

  testWidgets('nomor struk lokal tercatat & unik per transaksi', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await pumpPayment(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 25.000'));
    await tester.pump();

    final p = await tapBayar(tester);

    // Nomor yang tercetak di struk pelanggan WAJIB ikut tersimpan, kalau tidak
    // struk fisik tak merujuk apa pun yang bisa dicari saat komplain.
    expect(p['localReceiptNo'], matches(RegExp(r'^[A-Z0-9]{2}-\d{3}$')));
    expect(p['localReceiptNo'], endsWith('-001'));
  });

  testWidgets('dobel-tap Bayar tidak menggandakan transaksi', (tester) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await pumpPayment(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 25.000'));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.textContaining('Bayar '));
      await tester.tap(find.textContaining('Bayar '), warnIfMissed: false);
      await Future.delayed(const Duration(milliseconds: 400));
    });

    expect(
      OfflineQueueService.instance.all(),
      hasLength(1),
      reason: 'tombol harus terkunci setelah tap pertama',
    );
  });

  testWidgets('lease kedaluwarsa menolak transaksi sebelum antre dan cetak', (
    tester,
  ) async {
    when(() => posBloc.state).thenReturn(_stateWithCart());
    await tester.runAsync(() async => StaffAuthorizationLease.revoke(_kasirId));
    await pumpPayment(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rp 25.000'));
    await tester.pump();

    await tester.tap(find.textContaining('Bayar '));
    await tester.pump();

    expect(OfflineQueueService.instance.all(), isEmpty);
    expect(
      find.textContaining('Otorisasi kasir telah berakhir'),
      findsOneWidget,
    );
  });

  testWidgets(
    'split payment offline menyimpan seluruh metode ke satu antrean',
    (tester) async {
      ConnectivityService.instance.online.value = false;
      when(() => posBloc.state).thenReturn(_stateWithCart());
      await pumpPayment(tester);

      await tester.tap(find.text('Bagi Tagihan'));
      await tester.pumpAndSettle();
      expect(find.text('Tambah Pembayaran'), findsOneWidget);

      final amount = find.byType(TextField).last;
      await tester.enterText(amount, '10.000');
      await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('QRIS').last);
      await tester.enterText(amount, '14.000');
      await tester.runAsync(() async {
        // Pembayaran terakhir sekarang langsung memfinalisasi transaksi;
        // tidak ada lagi tombol finalisasi kedua yang wajib ditekan.
        await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });

      final pending = OfflineQueueService.instance.all();
      expect(pending, hasLength(1));
      final payments = (pending.single.value['payments'] as List).cast<Map>();
      expect(payments.map((payment) => payment['method']), ['cash', 'qris']);
      expect(payments.map((payment) => payment['amount']), [10000, 14000]);
      expect(
        payments.every(
          (payment) => (payment['idempotencyKey'] as String).isNotEmpty,
        ),
        isTrue,
      );
    },
  );
}

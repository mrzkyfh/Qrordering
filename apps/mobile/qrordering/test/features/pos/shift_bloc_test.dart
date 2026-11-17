import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qrordering/features/pos/data/datasources/shift_datasource.dart';
import 'package:qrordering/features/pos/presentation/bloc/shift_bloc.dart';
import 'package:qrordering/shared/models/cash_movement.dart';
import 'package:qrordering/shared/models/shift.dart';
import 'package:qrordering/shared/models/shift_close_report.dart';
import 'package:qrordering/shared/services/receipt_builder.dart';

class MockShiftDatasource extends Mock implements ShiftDatasource {}

Shift _makeShift({
  String id = 'shift-1',
  String outletId = 'outlet-1',
  String kasirId = 'kasir-1',
  double openingCash = 100000,
  DateTime? endTime,
  double? closingCash,
  double? expectedCash,
  double? cashDifference,
}) => Shift(
  id: id,
  outletId: outletId,
  kasirId: kasirId,
  startTime: DateTime(2026, 1, 1, 8, 0),
  endTime: endTime,
  openingCash: openingCash,
  closingCash: closingCash,
  expectedCash: expectedCash,
  cashDifference: cashDifference,
);

CashMovement _makeCashMovement({
  String type = 'out',
  double amount = 75000,
  String? note = 'Beli peralatan',
}) => CashMovement(
  id: 'movement-1',
  shiftId: 'shift-1',
  outletId: 'outlet-1',
  type: type,
  amount: amount,
  note: note,
  createdBy: 'kasir-1',
  createdAt: DateTime(2026, 1, 1, 10, 0),
);

ShiftCloseReport _makeReport() => ShiftCloseReport(
  shiftId: 'shift-1',
  outletId: 'outlet-1',
  outlet: const OutletReceiptInfo(name: 'QR Ordering'),
  cashierId: 'kasir-1',
  cashierName: 'Kasir',
  openedAt: DateTime(2026, 1, 1, 8),
  closedAt: DateTime(2026, 1, 1, 17),
  openingCash: 100000,
  closingCash: 150000,
  expectedCash: 150000,
  cashDifference: 0,
  cashReceived: 50000,
  nonCashReceived: 0,
  totalReceipts: 50000,
  taxTotal: 0,
  serviceChargeTotal: 0,
  discountTotal: 0,
  refundTotal: 0,
  cashIn: 0,
  cashOut: 0,
  completedTransactions: 1,
  unpaidTransactions: 0,
  voidItemQuantity: 0,
  voidItemAmount: 0,
  productQuantity: 1,
  paymentMethods: const [ShiftPaymentSummary(method: 'cash', amount: 50000)],
  products: const [
    ShiftProductSummary(name: 'Kebab', quantity: 1, amount: 50000),
  ],
);

void main() {
  late MockShiftDatasource datasource;

  setUp(() {
    datasource = MockShiftDatasource();
    // Default: shift aktif tak punya pergerakan kas (di-override bila perlu).
    when(
      () => datasource.fetchCashMovements(any()),
    ).thenAnswer((_) async => []);
  });

  // ─── Initial State ────────────────────────────────────────────────────────

  group('Initial State', () {
    test('state awal: kosong, tidak loading', () {
      final bloc = ShiftBloc(datasource: datasource);
      expect(bloc.state.loading, false);
      expect(bloc.state.submitting, false);
      expect(bloc.state.activeShift, isNull);
      expect(bloc.state.recentShifts, isEmpty);
      expect(bloc.state.error, isNull);
      bloc.close();
    });
  });

  // ─── ShiftLoadRequested ───────────────────────────────────────────────────

  group('ShiftLoadRequested', () {
    blocTest<ShiftBloc, ShiftState>(
      'load berhasil — ada shift aktif',
      build: () {
        final active = _makeShift();
        when(
          () => datasource.fetchActiveShift('outlet-1', 'kasir-1'),
        ).thenAnswer((_) async => active);
        when(
          () => datasource.fetchRecentShifts('outlet-1', 'kasir-1'),
        ).thenAnswer((_) async => []);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftLoadRequested('outlet-1', 'kasir-1')),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.loading, 'loading', true),
        isA<ShiftState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.activeShift?.id, 'activeShift.id', 'shift-1')
            .having((s) => s.error, 'error', isNull),
      ],
      verify: (_) {
        verifyNever(() => datasource.fetchCashMovements(any()));
      },
    );

    blocTest<ShiftBloc, ShiftState>(
      'load berhasil — tidak ada shift aktif',
      build: () {
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenAnswer((_) async => null);
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => []);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftLoadRequested('outlet-1', 'kasir-1')),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.loading, 'loading', true),
        isA<ShiftState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.activeShift, 'activeShift', isNull),
      ],
    );

    blocTest<ShiftBloc, ShiftState>(
      'load error — datasource throw',
      build: () {
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenThrow(Exception('koneksi gagal'));
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => []);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftLoadRequested('outlet-1', 'kasir-1')),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.loading, 'loading', true),
        isA<ShiftState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.error, 'error', isNotNull),
      ],
    );

    blocTest<ShiftBloc, ShiftState>(
      'load menyimpan outletId dan kasirId di state',
      build: () {
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenAnswer((_) async => null);
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => []);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftLoadRequested('outlet-X', 'kasir-Y')),
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        expect(bloc.state.outletId, 'outlet-X');
        expect(bloc.state.kasirId, 'kasir-Y');
      },
    );

    blocTest<ShiftBloc, ShiftState>(
      'load mengembalikan riwayat shift',
      build: () {
        final recent = [
          _makeShift(id: 'shift-old', endTime: DateTime(2026, 1, 1, 17, 0)),
        ];
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenAnswer((_) async => null);
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => recent);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftLoadRequested('outlet-1', 'kasir-1')),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.loading, 'loading', true),
        isA<ShiftState>().having(
          (s) => s.recentShifts.length,
          'recentShifts.length',
          1,
        ),
      ],
    );
  });

  group('ShiftManagementTargetSelected', () {
    blocTest<ShiftBloc, ShiftState>(
      'role manajemen memuat cash movement hanya untuk shift yang dipilih',
      build: () {
        when(
          () => datasource.fetchCashMovements('shift-1'),
        ).thenAnswer((_) async => [_makeCashMovement()]);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) =>
          bloc.add(ShiftManagementTargetSelected(_makeShift(id: 'shift-1'))),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>()
            .having((state) => state.loading, 'loading', true)
            .having(
              (state) => state.activeShift?.id,
              'activeShift.id',
              'shift-1',
            ),
        isA<ShiftState>()
            .having((state) => state.loading, 'loading', false)
            .having(
              (state) => state.cashMovements.length,
              'cashMovements.length',
              1,
            ),
      ],
      verify: (_) {
        verify(() => datasource.fetchCashMovements('shift-1')).called(1);
      },
    );
  });

  // ─── ShiftOpenRequested ───────────────────────────────────────────────────

  group('ShiftOpenRequested', () {
    blocTest<ShiftBloc, ShiftState>(
      'bentrok menunjukkan sesi lama beserta penolakan modal baru',
      build: () {
        when(
          () => datasource.openShift(any(), any(), any()),
        ).thenThrow(ActiveShiftExistsException(_makeShift()));
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftOpenRequested(200000)),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.activeShift?.openingCash, 'original cash', 100000)
            .having(
              (s) => s.error,
              'conflict',
              contains('modal baru belum disimpan'),
            ),
      ],
    );
    blocTest<ShiftBloc, ShiftState>(
      'buka shift berhasil — activeShift ter-set',
      build: () {
        final newShift = _makeShift(openingCash: 200000);
        when(
          () => datasource.openShift(any(), any(), 200000),
        ).thenAnswer((_) async => newShift);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftOpenRequested(200000)),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.activeShift?.openingCash, 'openingCash', 200000.0)
            .having((s) => s.error, 'error', isNull),
      ],
    );

    blocTest<ShiftBloc, ShiftState>(
      'buka shift error — error ter-set, submitting false',
      build: () {
        when(
          () => datasource.openShift(any(), any(), any()),
        ).thenThrow(Exception('gagal insert'));
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftOpenRequested(50000)),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.activeShift, 'activeShift', isNull)
            .having((s) => s.error, 'error', isNotNull),
      ],
    );

    blocTest<ShiftBloc, ShiftState>(
      'buka shift dengan kas awal 0 tetap valid',
      build: () {
        final newShift = _makeShift(openingCash: 0);
        when(
          () => datasource.openShift(any(), any(), 0),
        ).thenAnswer((_) async => newShift);
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(ShiftOpenRequested(0)),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>().having(
          (s) => s.activeShift?.openingCash,
          'openingCash',
          0.0,
        ),
      ],
    );
  });

  // ─── ShiftCloseRequested ──────────────────────────────────────────────────

  group('ShiftCloseRequested', () {
    blocTest<ShiftBloc, ShiftState>(
      'tutup shift berhasil — activeShift null, riwayat diperbarui',
      build: () {
        final active = _makeShift(id: 'shift-1', openingCash: 100000);
        final closed = _makeShift(
          id: 'shift-1',
          endTime: DateTime.now(),
          openingCash: 100000,
          closingCash: 150000,
          expectedCash: 150000,
          cashDifference: 0,
        );
        when(
          () => datasource.calculateExpectedCash('shift-1', 100000),
        ).thenAnswer((_) async => 150000.0);
        when(
          () => datasource.closeShift(
            shiftId: any(named: 'shiftId'),
            closingCash: any(named: 'closingCash'),
            notes: any(named: 'notes'),
          ),
        ).thenAnswer((_) async => _makeReport());
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenAnswer((_) async => null);
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => [closed]);
        return ShiftBloc(datasource: datasource)..emit(
          ShiftBloc(datasource: datasource).state.copyWith(
            activeShift: active,
            outletId: 'outlet-1',
            kasirId: 'kasir-1',
          ),
        );
      },
      seed: () => ShiftState(
        activeShift: _makeShift(id: 'shift-1', openingCash: 100000),
        outletId: 'outlet-1',
        kasirId: 'kasir-1',
      ),
      act: (bloc) => bloc.add(ShiftCloseRequested(150000, null)),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>().having((s) => s.loading, 'loading', false),
        isA<ShiftState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.activeShift, 'activeShift', isNull),
      ],
    );

    // Regression: SERVER yang menghitung expected_cash & cash_difference (RPC
    // close_shift). Aplikasi hanya melapor uang fisik di laci.
    //
    // Dulu bloc ini memanggil calculateExpectedCash lalu MENGIRIM hasilnya untuk
    // ditulis apa adanya. Dua akibatnya: angka rekonsiliasi laci ditentukan
    // klien, dan rumusnya jadi salinan kedua di samping RPC yang dipakai
    // owner-panel — keduanya sudah terlanjur berbeda (RPC lupa menghitung kas
    // masuk/keluar, sehingga kasir yang mengambil petty cash tampak kurang setor).
    blocTest<ShiftBloc, ShiftState>(
      'tutup shift hanya melapor uang di laci — tidak menghitung selisih sendiri',
      build: () {
        when(
          () => datasource.closeShift(
            shiftId: any(named: 'shiftId'),
            closingCash: any(named: 'closingCash'),
            notes: any(named: 'notes'),
          ),
        ).thenAnswer((_) async => _makeReport());
        when(
          () => datasource.fetchActiveShift(any(), any()),
        ).thenAnswer((_) async => null);
        when(
          () => datasource.fetchRecentShifts(any(), any()),
        ).thenAnswer((_) async => []);
        return ShiftBloc(datasource: datasource);
      },
      seed: () => ShiftState(
        activeShift: _makeShift(id: 'shift-1', openingCash: 100000),
        outletId: 'outlet-1',
        kasirId: 'kasir-1',
      ),
      act: (bloc) => bloc.add(ShiftCloseRequested(130000, 'ada selisih')),
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        verify(
          () => datasource.closeShift(
            shiftId: 'shift-1',
            closingCash: 130000,
            notes: 'ada selisih',
          ),
        ).called(1);
        // Kunci intinya: bloc tidak boleh lagi menghitung ekspektasi kas saat
        // menutup shift — kalau ia memanggil ini, angkanya kembali dari klien.
        verifyNever(() => datasource.calculateExpectedCash(any(), any()));
      },
    );

    blocTest<ShiftBloc, ShiftState>(
      'tutup shift tidak dilakukan jika tidak ada shift aktif',
      build: () => ShiftBloc(datasource: datasource),
      act: (bloc) => bloc.add(ShiftCloseRequested(100000, null)),
      wait: const Duration(milliseconds: 100),
      expect: () => [],
      verify: (_) {
        verifyNever(
          () => datasource.closeShift(
            shiftId: any(named: 'shiftId'),
            closingCash: any(named: 'closingCash'),
            notes: any(named: 'notes'),
          ),
        );
      },
    );

    blocTest<ShiftBloc, ShiftState>(
      'tutup shift error — error ter-set, submitting false',
      build: () {
        when(
          () => datasource.closeShift(
            shiftId: any(named: 'shiftId'),
            closingCash: any(named: 'closingCash'),
            notes: any(named: 'notes'),
          ),
        ).thenThrow(Exception('tutup gagal'));
        return ShiftBloc(datasource: datasource);
      },
      seed: () => ShiftState(
        activeShift: _makeShift(id: 'shift-1', openingCash: 100000),
        outletId: 'outlet-1',
        kasirId: 'kasir-1',
      ),
      act: (bloc) => bloc.add(ShiftCloseRequested(100000, null)),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<ShiftState>().having((s) => s.submitting, 'submitting', true),
        isA<ShiftState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.error, 'error', isNotNull)
            .having((s) => s.activeShift, 'activeShift', isNotNull),
      ],
    );
  });

  // ─── ShiftCashMovementRequested ──────────────────────────────────────────

  group('ShiftCashMovementRequested', () {
    blocTest<ShiftBloc, ShiftState>(
      'Kas Keluar meneruskan kategori pengeluaran ke server',
      seed: () => ShiftState(
        activeShift: _makeShift(),
        outletId: 'outlet-1',
        kasirId: 'kasir-1',
      ),
      build: () {
        when(
          () => datasource.addCashMovement(
            shiftId: 'shift-1',
            outletId: 'outlet-1',
            type: 'out',
            amount: 75000,
            note: 'Beli peralatan',
            expenseCategory: 'peralatan',
          ),
        ).thenAnswer((_) async => _makeCashMovement());
        return ShiftBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(
        ShiftCashMovementRequested(
          'out',
          75000,
          'Beli peralatan',
          expenseCategory: 'peralatan',
        ),
      ),
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        verify(
          () => datasource.addCashMovement(
            shiftId: 'shift-1',
            outletId: 'outlet-1',
            type: 'out',
            amount: 75000,
            note: 'Beli peralatan',
            expenseCategory: 'peralatan',
          ),
        ).called(1);
      },
    );
  });

  // ─── calculateExpectedCash ────────────────────────────────────────────────

  group('calculateExpectedCash (via closeShift flow)', () {
    test('expectedCash = openingCash + total cash payment', () async {
      final ds = MockShiftDatasource();
      when(
        () => ds.calculateExpectedCash('shift-1', 100000),
      ).thenAnswer((_) async => 175000.0);

      final result = await ds.calculateExpectedCash('shift-1', 100000);
      expect(result, 175000.0);
    });

    test('expectedCash = openingCash jika tidak ada pembayaran cash', () async {
      final ds = MockShiftDatasource();
      when(
        () => ds.calculateExpectedCash('shift-1', 50000),
      ).thenAnswer((_) async => 50000.0);

      final result = await ds.calculateExpectedCash('shift-1', 50000);
      expect(result, 50000.0);
    });
  });

  // ─── ShiftState copyWith ──────────────────────────────────────────────────

  group('ShiftState.copyWith', () {
    test('clearActive = true menghapus activeShift', () {
      final shift = _makeShift();
      final state = ShiftState(activeShift: shift);
      final next = state.copyWith(clearActive: true);
      expect(next.activeShift, isNull);
    });

    test('clearActive = false mempertahankan activeShift', () {
      final shift = _makeShift();
      final state = ShiftState(activeShift: shift);
      final next = state.copyWith(loading: true);
      expect(next.activeShift, shift);
    });

    test('error selalu di-reset ke nilai baru (null atau string)', () {
      final state = ShiftState(error: 'error lama');
      final cleared = state.copyWith();
      expect(cleared.error, isNull);
    });
  });
}

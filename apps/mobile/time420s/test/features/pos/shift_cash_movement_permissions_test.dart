import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';
import 'package:time420s/features/pos/data/datasources/shift_datasource.dart';
import 'package:time420s/features/pos/presentation/bloc/shift_bloc.dart';
import 'package:time420s/features/pos/presentation/pages/shift_page.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/shift.dart';

class _MockShiftDatasource extends Mock implements ShiftDatasource {}

Shift _shift() => Shift(
  id: 'shift-1',
  outletId: 'outlet-1',
  kasirId: 'staff-1',
  startTime: DateTime(2026, 7, 27, 8),
  openingCash: 100000,
);

void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

  test('izin Kas Masuk/Keluar hanya untuk role manajemen', () {
    expect(canManageCashMovements(UserRole.owner), isTrue);
    expect(canManageCashMovements(UserRole.admin), isTrue);
    expect(canManageCashMovements(UserRole.manajer), isTrue);
    expect(canManageCashMovements(UserRole.kasir), isFalse);
    expect(canManageCashMovements(UserRole.pelanggan), isFalse);
    expect(canManageCashMovements(null), isFalse);
  });

  testWidgets('role kasir tidak melihat Kas Masuk dan Kas Keluar', (
    tester,
  ) async {
    final bloc = ShiftBloc(datasource: _MockShiftDatasource());
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: bloc,
            child: activeShiftCardForTesting(
              shift: _shift(),
              role: UserRole.kasir,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Kas Masuk'), findsNothing);
    expect(find.text('Kas Keluar'), findsNothing);
    expect(find.text('Tutup Shift'), findsOneWidget);
  });

  testWidgets('role manajemen tetap melihat Kas Masuk dan Kas Keluar', (
    tester,
  ) async {
    final bloc = ShiftBloc(datasource: _MockShiftDatasource());
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: bloc,
            child: activeShiftCardForTesting(
              shift: _shift(),
              role: UserRole.manajer,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Kas Masuk'), findsOneWidget);
    expect(find.text('Kas Keluar'), findsOneWidget);
  });

  testWidgets('role manajemen memilih shift kasir aktif sebelum mencatat kas', (
    tester,
  ) async {
    final datasource = _MockShiftDatasource();
    final shift = Shift(
      id: 'shift-siti',
      outletId: 'outlet-1',
      kasirId: 'kasir-siti',
      cashierName: 'Siti Kasir',
      startTime: DateTime(2026, 7, 27, 8),
      openingCash: 150000,
    );
    when(
      () => datasource.fetchActiveShiftsForManagement('outlet-1'),
    ).thenAnswer((_) async => [shift]);
    when(
      () => datasource.fetchCashMovements('shift-siti'),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ManagementCashMovementSection(
              outletId: 'outlet-1',
              datasource: datasource,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(const Key('management-shift-selector')), findsOneWidget);
    expect(find.textContaining('Siti Kasir'), findsOneWidget);
    expect(find.text('Kas Masuk'), findsOneWidget);
    expect(find.text('Kas Keluar'), findsOneWidget);
    expect(find.text('Tutup Shift'), findsNothing);
    verify(
      () => datasource.fetchActiveShiftsForManagement('outlet-1'),
    ).called(1);
    verify(() => datasource.fetchCashMovements('shift-siti')).called(1);
    expect(tester.takeException(), isNull);
  });
}

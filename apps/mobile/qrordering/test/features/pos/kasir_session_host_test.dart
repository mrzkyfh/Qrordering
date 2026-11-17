import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qrordering/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qrordering/features/pos/data/datasources/shift_datasource.dart';
import 'package:qrordering/features/pos/presentation/bloc/shift_bloc.dart';
import 'package:qrordering/features/pos/presentation/pages/kasir_shell.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/profile.dart';
import 'package:qrordering/shared/models/shift.dart';

class _Auth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _Shifts extends MockBloc<ShiftEvent, ShiftState> implements ShiftBloc {}

class _Datasource extends Mock implements ShiftDatasource {}

void main() {
  late _Auth auth;
  late _Shifts shifts;
  late _Datasource datasource;
  final oldShift = Shift(
    id: 'old',
    outletId: 'outlet',
    kasirId: 'cashier',
    startTime: DateTime(2026, 9, 2, 17, 42),
    openingCash: 0,
  );

  setUp(() {
    auth = _Auth();
    shifts = _Shifts();
    datasource = _Datasource();
    when(() => shifts.datasource).thenReturn(datasource);
    when(() => auth.state).thenReturn(
      AuthAuthenticated(
        profile: Profile(
          id: 'cashier',
          outletId: 'outlet',
          role: UserRole.kasir,
          fullName: 'Kasir',
          isActive: true,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ),
    );
  });

  Future<void> mount(WidgetTester tester, ShiftState state) async {
    when(() => shifts.state).thenReturn(state);
    final router = GoRouter(
      initialLocation: '/kasir',
      routes: [
        GoRoute(
          path: '/kasir',
          builder: (_, _) => const Scaffold(
            body: KasirSessionHost(child: Text('POS content')),
          ),
        ),
        GoRoute(
          path: '/kasir/shift',
          builder: (_, _) => const Scaffold(body: Text('Review session')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<ShiftBloc>.value(value: shifts),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('loading tidak mengaku belum ada sesi atau membuka dialog', (
    tester,
  ) async {
    await mount(
      tester,
      const ShiftState(loading: true, outletId: 'outlet', kasirId: 'cashier'),
    );
    expect(find.text('Buka Kasir?'), findsNothing);
    expect(find.text('POS content'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('gagal memuat status menyediakan retry tanpa dialog buka', (
    tester,
  ) async {
    await mount(
      tester,
      const ShiftState(
        outletId: 'outlet',
        kasirId: 'cashier',
        error: 'Tidak dapat terhubung ke server.',
      ),
    );
    expect(find.text('Buka Kasir?'), findsNothing);
    expect(find.text('Status Kasir Belum Terverifikasi'), findsOneWidget);
    await tester.tap(find.text('Coba Lagi'));
    verify(() => shifts.add(ShiftLoadRequested('outlet', 'cashier'))).called(1);
  });

  testWidgets('sesi akun lain tidak membuka akses POS', (tester) async {
    await mount(
      tester,
      ShiftState(outletId: 'outlet', kasirId: 'other', activeShift: oldShift),
    );
    expect(find.text('POS content'), findsNothing);
    expect(find.text('Buka Kasir?'), findsNothing);
  });

  testWidgets('sesi aktif membuka akses POS tanpa banner tambahan', (
    tester,
  ) async {
    await mount(
      tester,
      ShiftState(outletId: 'outlet', kasirId: 'cashier', activeShift: oldShift),
    );
    expect(find.text('Buka Kasir?'), findsNothing);
    expect(find.text('POS content'), findsOneWidget);
    expect(find.textContaining('Sesi kasir aktif sejak'), findsNothing);
    expect(find.text('Lihat Sesi'), findsNothing);
  });

  testWidgets('isi modal lalu bentrok tidak menampilkan sukses pembukaan', (
    tester,
  ) async {
    when(
      () => datasource.openShift('outlet', 'cashier', 125000),
    ).thenThrow(ActiveShiftExistsException(oldShift));
    await mount(
      tester,
      const ShiftState(outletId: 'outlet', kasirId: 'cashier'),
    );
    expect(find.text('Buka Kasir?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '125000');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Buka Kasir'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('modal baru belum disimpan'), findsOneWidget);
    expect(find.text('Kasir berhasil dibuka.'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(FilledButton, 'Buka Kasir'),
            ),
          )
          .onPressed,
      isNull,
    );
    verify(() => shifts.add(ShiftLoadRequested('outlet', 'cashier'))).called(1);
    await tester.tap(find.text('Lihat Sesi Aktif'));
    await tester.pumpAndSettle();
    expect(find.text('Review session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('buka baru berhasil menyimpan modal dan memuat sesi server', (
    tester,
  ) async {
    when(() => datasource.openShift('outlet', 'cashier', 75000)).thenAnswer(
      (_) async => Shift(
        id: 'new',
        outletId: 'outlet',
        kasirId: 'cashier',
        startTime: DateTime(2026, 9, 4, 14, 46),
        openingCash: 75000,
      ),
    );
    await mount(
      tester,
      const ShiftState(outletId: 'outlet', kasirId: 'cashier'),
    );
    await tester.enterText(find.byType(TextField), '75000');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Buka Kasir'),
      ),
    );
    await tester.pumpAndSettle();
    verify(() => datasource.openShift('outlet', 'cashier', 75000)).called(1);
    verify(() => shifts.add(ShiftLoadRequested('outlet', 'cashier'))).called(1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Kasir berhasil dibuka.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Nanti Saja menutup dialog tanpa membuat sesi', (tester) async {
    await mount(
      tester,
      const ShiftState(outletId: 'outlet', kasirId: 'cashier'),
    );
    await tester.tap(find.text('Nanti Saja'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    verifyZeroInteractions(datasource);
    expect(tester.takeException(), isNull);
  });
}

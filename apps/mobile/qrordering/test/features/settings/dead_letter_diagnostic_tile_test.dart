import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/settings/presentation/pages/device_monitor_page.dart';
import 'package:qrordering/shared/services/offline_queue_service.dart';

void main() {
  testWidgets('detail transaksi ditolak tetap terbaca pada layar sempit', (
    tester,
  ) async {
    var copied = false;
    var retried = false;
    final diagnostic = DeadLetterDiagnostic(
      key: 17,
      error:
          'Bad state: Offline sync rejected [2R-001]: 22023 Till sudah '
          'ditutup dan tidak ada till aktif yang sesuai waktu transaksi',
      failedAt: '2026-07-31T13:15:22.000Z',
      payload: const {
        'localReceiptNo': '2R-001',
        'clientOrderId': 'd9342cf4-270c-48c3-9599-b22c35f665bc',
        'shiftId': '2f89c93d-80bc-4913-a2af-64aa315c35ce',
        'originalShiftId': '2f89c93d-80bc-4913-a2af-64aa315c35ce',
        'createdAt': '2026-07-31T12:42:00.000Z',
        'createdBy': 'ab23713a-c52f-4693-abdd-452169de21c4',
        'shiftStartedAt': '2026-07-30T10:00:00.000Z',
        'shiftVerifiedAt': '2026-07-31T12:40:00.000Z',
        'shiftSource': 'cache_offline',
        'payments': [
          {'method': 'cash', 'amount': 25000},
          {'method': 'qris', 'amount': 31000},
        ],
      },
    );

    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DeadLetterDiagnosticTile(
              diagnostic: diagnostic,
              busy: false,
              onCopy: () => copied = true,
              onRetry: () => retried = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('2R-001'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('2R-001'));
    await tester.pumpAndSettle();

    expect(find.text('ID TILL TRANSAKSI'), findsOneWidget);
    expect(find.text('2f89c93d-80bc-4913-a2af-64aa315c35ce'), findsNWidgets(2));
    expect(find.text('cash: 25000, qris: 31000'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Salin detail'));
    await tester.tap(find.text('Salin detail'));
    await tester.pump();
    expect(copied, isTrue);

    await tester.ensureVisible(find.text('Coba transaksi ini'));
    await tester.tap(find.text('Coba transaksi ini'));
    await tester.pump();
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });
}

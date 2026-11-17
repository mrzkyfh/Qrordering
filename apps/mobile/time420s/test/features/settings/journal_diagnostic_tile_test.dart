import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/settings/presentation/pages/device_monitor_page.dart';
import 'package:time420s/shared/services/transaction_journal_service.dart';

void main() {
  Future<void> pumpTile(
    WidgetTester tester,
    TransactionJournalDiagnostic diagnostic, {
    required VoidCallback onCopy,
    VoidCallback? onRetry,
  }) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: JournalDiagnosticTile(
              diagnostic: diagnostic,
              busy: false,
              onCopy: onCopy,
              onRetry: onRetry,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'detail split payment terbaca dan dapat diretry di layar sempit',
    (tester) async {
      var copied = false;
      var retried = false;
      final diagnostic = TransactionJournalDiagnostic(
        storageKey: 'split-payment-long-key',
        id: 'split-payment-7e7c3adf-92ee-4b6f-a443-56578287ab91',
        type: 'split_payment',
        status: 'needs_review',
        attempts: 3,
        createdAt: '2026-07-31T10:00:00.000Z',
        updatedAt: '2026-07-31T10:10:00.000Z',
        lastError:
            'PostgrestException 22023: Shift pembayaran sudah ditutup dan '
            'membutuhkan pemeriksaan status transaksi terbaru',
        payload: const {
          'orderId': 'order-very-long-7e7c3adf-92ee-4b6f-a443-56578287ab91',
          'outletId': 'outlet-1',
          'shiftId': 'shift-old-1',
          'expectedUserId': 'cashier-1',
          'method': 'qris',
          'amount': 31000,
        },
      );

      await pumpTile(
        tester,
        diagnostic,
        onCopy: () => copied = true,
        onRetry: () => retried = true,
      );

      expect(find.text('Bagian split payment'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Bagian split payment'));
      await tester.pumpAndSettle();

      expect(find.text('ID JURNAL'), findsOneWidget);
      expect(find.text('qris · 31000'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Salin detail'));
      await tester.tap(find.text('Salin detail'));
      await tester.pump();
      expect(copied, isTrue);

      await tester.ensureVisible(find.text('Coba pembayaran ini'));
      await tester.tap(find.text('Coba pembayaran ini'));
      await tester.pump();
      expect(retried, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('operasi void hanya memberi panduan tanpa tombol retry', (
    tester,
  ) async {
    final diagnostic = TransactionJournalDiagnostic(
      storageKey: 'manual-1',
      id: 'manual-1',
      type: 'manual_review',
      status: 'needs_review',
      attempts: 1,
      createdAt: '2026-07-31T10:00:00.000Z',
      updatedAt: '2026-07-31T10:10:00.000Z',
      lastError: 'Menunggu verifikasi PIN saat online',
      payload: const {'operation': 'void_order', 'orderId': 'order-void-1'},
    );

    await pumpTile(tester, diagnostic, onCopy: () {});
    await tester.tap(find.text('Void order perlu verifikasi'));
    await tester.pumpAndSettle();

    expect(find.text('Coba pembayaran ini'), findsNothing);
    expect(
      find.text(
        'Buka detail order saat online, lalu ulangi dengan persetujuan dan PIN.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

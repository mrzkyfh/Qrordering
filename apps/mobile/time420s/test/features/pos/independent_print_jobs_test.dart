import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/pos/presentation/pages/payment_page.dart';

void main() {
  test('tiket dapur tetap dijalankan ketika struk sengaja dilewati', () async {
    var kitchenRuns = 0;

    await runIndependentPrintJobs(
      receiptJob: () async => Future<void>.value(),
      kitchenJob: () async => kitchenRuns++,
    );

    expect(kitchenRuns, 1);
  });

  test('kegagalan struk tidak menghentikan tiket dapur', () async {
    var kitchenRuns = 0;
    Object? receiptError;

    await runIndependentPrintJobs(
      receiptJob: () async => throw StateError('printer struk putus'),
      kitchenJob: () async => kitchenRuns++,
      onReceiptError: (error) => receiptError = error,
    );

    expect(kitchenRuns, 1);
    expect(receiptError, isA<StateError>());
  });

  test(
    'kegagalan dapur dilaporkan tanpa mengubah hasil pekerjaan struk',
    () async {
      var receiptRuns = 0;
      Object? kitchenError;

      await runIndependentPrintJobs(
        receiptJob: () async => receiptRuns++,
        kitchenJob: () async => throw StateError('printer dapur putus'),
        onKitchenError: (error) => kitchenError = error,
      );

      expect(receiptRuns, 1);
      expect(kitchenError, isA<StateError>());
    },
  );
}

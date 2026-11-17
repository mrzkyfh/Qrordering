import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/services/error_log_service.dart';

void main() {
  group('ErrorLogPolicy', () {
    final start = DateTime.utc(2026, 7, 23, 10);

    test('error identik hanya diterima sekali dalam satu window', () {
      final policy = ErrorLogPolicy(startedAt: start);

      expect(policy.shouldReport('boom', 'stack:1', now: start), isTrue);
      expect(
        policy.shouldReport(
          'boom',
          'stack:1\nbaris lain berubah',
          now: start.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
    });

    test('error unik dibatasi dan window dapat direset', () {
      final policy = ErrorLogPolicy(
        maxUniquePerWindow: 2,
        window: const Duration(minutes: 1),
        startedAt: start,
      );

      expect(policy.shouldReport('a', null, now: start), isTrue);
      expect(policy.shouldReport('b', null, now: start), isTrue);
      expect(policy.shouldReport('c', null, now: start), isFalse);
      expect(
        policy.shouldReport(
          'c',
          null,
          now: start.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });
  });

  test('field panjang dipotong tanpa melewati batas', () {
    final result = limitErrorLogField('x' * 500, 100);

    expect(result.length, 100);
    expect(result, endsWith('[dipotong]'));
    expect(limitErrorLogField('pendek', 100), 'pendek');
  });
}

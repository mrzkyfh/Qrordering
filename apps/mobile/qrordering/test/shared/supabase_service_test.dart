import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/services/supabase_service.dart';

void main() {
  group('hasCompleteDeviceCredentials', () {
    test('menerima pasangan email dan password lengkap', () {
      expect(
        hasCompleteDeviceCredentials('device@example.com', 'rahasia'),
        isTrue,
      );
    });

    test('menolak secure storage parsial', () {
      expect(hasCompleteDeviceCredentials('device@example.com', null), isFalse);
      expect(hasCompleteDeviceCredentials(null, 'rahasia'), isFalse);
      expect(hasCompleteDeviceCredentials('', 'rahasia'), isFalse);
      expect(
        hasCompleteDeviceCredentials('device@example.com', '   '),
        isFalse,
      );
    });
  });
}

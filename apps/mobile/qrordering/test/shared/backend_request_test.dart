import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/shared/services/backend_request.dart';

void main() {
  test('gateway PostgREST sementara dapat dialihkan ke offline/fallback', () {
    expect(
      isBackendTemporarilyUnavailable(
        const PostgrestException(
          message: 'PostgREST temporarily unavailable',
          code: 'PGRST002',
        ),
      ),
      isTrue,
    );
  });

  test('constraint dan RLS tetap dianggap penolakan bisnis', () {
    expect(
      isBackendTemporarilyUnavailable(
        const PostgrestException(message: 'constraint', code: '23514'),
      ),
      isFalse,
    );
    expect(
      isBackendTemporarilyUnavailable(
        const PostgrestException(message: 'forbidden', code: '42501'),
      ),
      isFalse,
    );
  });

  test('Edge Function 5xx sementara, tetapi 4xx tetap otoritatif', () {
    expect(
      isBackendTemporarilyUnavailable(const FunctionException(status: 503)),
      isTrue,
    );
    expect(
      isBackendTemporarilyUnavailable(const FunctionException(status: 401)),
      isFalse,
    );
  });

  test('respons gateway tidak memicu failover host kedua', () {
    expect(
      isBackendTransportFailure(
        const PostgrestException(message: 'unavailable', code: 'PGRST002'),
      ),
      isFalse,
    );
  });
}

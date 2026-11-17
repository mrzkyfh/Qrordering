import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/services/supabase_service.dart';

void main() {
  test('query profil tidak meminta kolom PIN atau wildcard', () {
    expect(profileSelectColumns, isNot(contains('*')));
    expect(profileSelectColumns, isNot(contains('pin_hash')));
    expect(profileSelectColumns, isNot(contains('pin_failed')));
    expect(profileSelectColumns, contains('id'));
    expect(profileSelectColumns, contains('role'));
    expect(profileSelectColumns, contains('outlets(name)'));
  });
}

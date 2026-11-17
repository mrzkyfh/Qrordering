import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/216_idempotent_offline_cash_movements.sql',
  );

  test('kas masuk keluar offline idempoten dan tidak menggandakan expense', () {
    final sql = migration.readAsStringSync();

    expect(sql, contains('record_cash_movement_idempotent'));
    expect(sql, contains('pg_advisory_xact_lock'));
    expect(sql, contains('idx_cash_movements_request_id_unique'));
    expect(sql, contains('record_cash_movement_management_impl'));
    expect(sql, contains('WHERE cash_movement_id = v_movement_id'));
    expect(sql, contains("('owner', 'admin', 'manajer')"));
    expect(sql, contains('GRANT EXECUTE ON FUNCTION'));
    expect(sql, isNot(contains('qr_token')));
    expect(sql, isNot(contains('qr_code_url')));
  });
}

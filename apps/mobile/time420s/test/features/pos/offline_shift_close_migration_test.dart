import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/215_offline_shift_close.sql',
  );

  test('penutupan shift offline idempoten dan dihitung server', () async {
    final sql = await migration.readAsString();

    expect(sql, contains('close_shift_idempotent_with_report'));
    expect(sql, contains('FOR UPDATE'));
    expect(sql, contains('v_shift.end_time IS NOT NULL'));
    expect(
      sql,
      contains('v_shift.closing_cash IS DISTINCT FROM p_closing_cash'),
    );
    expect(sql, contains('PERFORM public.close_shift'));
    expect(sql, contains('RETURN public.get_shift_close_report'));
    expect(sql, contains('GRANT EXECUTE ON FUNCTION'));
    expect(sql, isNot(contains('qr_token')));
    expect(sql, isNot(contains('qr_code_url')));
  });
}

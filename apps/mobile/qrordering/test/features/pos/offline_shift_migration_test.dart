import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/212_offline_shift_open.sql',
  );

  test('RPC buka shift offline idempoten dan tetap membatasi akses', () async {
    final sql = await migration.readAsString();

    expect(sql, contains('open_shift_idempotent'));
    expect(sql, contains('WHERE id = p_shift_id'));
    expect(sql, contains('WHEN unique_violation'));
    expect(
      sql,
      contains("v_role NOT IN ('owner', 'admin', 'manajer', 'kasir')"),
    );
    expect(
      sql,
      contains('p_outlet_id IS DISTINCT FROM public.auth_outlet_id()'),
    );
    expect(
      sql,
      contains('GRANT EXECUTE ON FUNCTION public.open_shift_idempotent'),
    );
    expect(sql, isNot(contains('qr_token')));
    expect(sql, isNot(contains('qr_code_url')));
  });
}

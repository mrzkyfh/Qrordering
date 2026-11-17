import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/168_cash_movement_management_access.sql',
  ).readAsStringSync();

  test('RLS baca cash movement hanya membuka role manajemen', () {
    final policyStart = migration.indexOf(
      'CREATE POLICY "cash_movements_select"',
    );
    final policyEnd = migration.indexOf(
      'DROP POLICY IF EXISTS "cash_movements_insert"',
    );
    final policy = migration.substring(policyStart, policyEnd);

    expect(policy, contains("'admin', 'manajer'"));
    expect(policy, contains('public.is_owner()'));
    expect(policy, isNot(contains("'kasir'")));
  });

  test('RPC cash movement menolak kasir sebelum implementasi internal', () {
    final functionStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.record_cash_movement',
    );
    final functionEnd = migration.indexOf(
      'REVOKE ALL ON FUNCTION public.record_cash_movement(',
      functionStart,
    );
    final function = migration.substring(functionStart, functionEnd);

    expect(function, contains("'owner', 'admin', 'manajer'"));
    expect(function, isNot(contains("'kasir'")));
    expect(function, contains('record_cash_movement_management_impl'));
  });

  test('laporan kasir meredaksi rincian kas masuk keluar', () {
    expect(migration, contains("'cash_in', 0"));
    expect(migration, contains("'cash_out', 0"));
    expect(migration, contains("'expenses', '[]'::JSONB"));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/217_device_auth_boundary_hardening.sql',
  ).readAsStringSync();
  final clockInFunction = File(
    '../../supabase/functions/clock-in/index.ts',
  ).readAsStringSync();

  test(
    'clock-in server hanya menerima akun perangkat aktif di outlet sama',
    () {
      expect(clockInFunction, contains('!deviceProfile.is_active'));
      expect(clockInFunction, contains("deviceProfile.role !== 'pelanggan'"));
      expect(clockInFunction, contains('deviceProfile.outlet_id !== outletId'));
      expect(
        clockInFunction,
        isNot(contains("deviceProfile.role !== 'owner'")),
      );
    },
  );

  test('transisi role akun perangkat ditolak di database', () {
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.guard_device_role_transition',
      ),
    );
    expect(
      migration,
      contains(
        "(OLD.role = 'pelanggan') IS DISTINCT FROM (NEW.role = 'pelanggan')",
      ),
    );
    expect(migration, contains('BEFORE UPDATE OF role ON public.profiles'));
  });

  test('akun perangkat tidak mendapat policy tulis operasional', () {
    for (final policy in const [
      'shifts_insert',
      'shifts_update',
      'expenses_insert',
      'stock_tx_insert',
      'extras_insert',
      'extras_update',
      'extras_delete',
      'meo_insert',
      'meo_update',
      'meo_delete',
      'mie_insert',
      'mie_delete',
      'recipes_insert',
      'recipes_update',
      'recipes_delete',
    ]) {
      expect(migration, contains('POLICY "$policy"'));
    }
    expect(migration, isNot(contains("public.auth_role() = 'pelanggan'")));
    expect(migration, contains("public.auth_role() IN ('admin', 'manajer')"));
  });

  test('policy profil membatasi perangkat ke profil sendiri', () {
    expect(migration, contains('DROP POLICY IF EXISTS "profiles_select"'));
    expect(migration, contains('OR id = auth.uid()'));
    expect(
      migration,
      contains("public.auth_role() IN ('admin', 'manajer', 'kasir')"),
    );
  });

  test('migration keamanan tidak memutasi data atau tautan QR', () {
    expect(migration, isNot(contains('UPDATE public.')));
    expect(migration, isNot(contains('DELETE FROM public.')));
    expect(migration, isNot(contains('SET qr_token')));
    expect(migration, isNot(contains('SET qr_code_url')));
  });
}

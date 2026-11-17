import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    '../../supabase/migrations/220_refund_approver_permission.sql',
  ).readAsStringSync().toLowerCase();

  test('full dan partial refund memakai otorisasi approver fail-closed', () {
    expect(
      'public._find_refund_approver'.allMatches(migration),
      hasLength(greaterThanOrEqualTo(5)),
    );
    expect(migration, contains('coalesce(profile.can_refund, false)'));
    expect(migration, contains('profile.is_active'));
    expect(migration, contains('public.role_rank(profile.role) >= 2'));
    expect(
      migration,
      contains("profile.role = 'owner' or profile.outlet_id = p_outlet"),
    );
    expect(migration, contains('for update'));
  });

  test('izin approver diperiksa sebelum penulisan refund', () {
    final authorization = migration.indexOf(
      'select public._find_refund_approver',
    );
    final fullInsert = migration.indexOf('insert into public.refunds');
    final partialAuthorization = migration.indexOf(
      'v_approver := public._find_refund_approver',
    );
    final partialInsert = migration.indexOf(
      'insert into public.refunds',
      fullInsert + 1,
    );

    expect(authorization, greaterThanOrEqualTo(0));
    expect(fullInsert, greaterThan(authorization));
    expect(partialAuthorization, greaterThan(fullInsert));
    expect(partialInsert, greaterThan(partialAuthorization));
  });

  test('kasir peminta tidak diwajibkan memiliki can_refund', () {
    expect(
      migration,
      isNot(contains('can_refund from public.profiles where id = auth.uid()')),
    );
    expect(migration, contains('v_order.outlet_id = public.auth_outlet_id()'));
  });

  test('akuntansi, stok, signature, dan void tetap dipertahankan', () {
    expect(migration, contains('uuid, text, text, uuid'));
    expect(migration, contains('uuid, jsonb, text, text, uuid'));
    expect(migration, contains('public.restore_stock_for_order(p_order)'));
    expect(migration, contains('group by method'));
    expect(
      migration,
      contains('set refunded_qty = coalesce(refunded_qty, 0) + v_qty'),
    );
    expect(
      migration,
      isNot(contains('function public.void_order_with_approval')),
    );
    expect(migration, isNot(contains('function public.void_order_items')));
  });

  test('picker hanya mengekspos flag izin, bukan PIN', () {
    expect(
      migration,
      contains('coalesce(target.can_refund, false) as can_refund'),
    );
    expect(migration, contains('(target.pin_hash is not null) as has_pin'));
    expect(migration, isNot(contains('target.pin_hash,')));
  });
}

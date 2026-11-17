import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    '../../supabase/migrations/209_remove_self_order_per_table_limit.sql',
  ).readAsStringSync();
  final capacityLimitsSql = File(
    '../../supabase/migrations/214_remove_qr_order_capacity_limits.sql',
  ).readAsStringSync();
  final onlineSettings = File(
    'lib/features/settings/presentation/pages/order_online_setting_page.dart',
  ).readAsStringSync();

  test('migration menghapus blok limit 15 pada fungsi internal', () {
    expect(sql, contains('pg_get_functiondef'));
    expect(
      sql,
      contains("strpos(v_definition, 'SELECT count(*) INTO v_active')"),
    );
    expect(sql, contains('Meja ini punya terlalu banyak pesanan aktif'));
    expect(sql, contains('EXECUTE v_updated'));
    expect(sql, contains('IF v_updated = v_definition THEN'));
  });

  test('fungsi internal tetap tidak dapat dipanggil langsung', () {
    expect(sql, contains('FROM PUBLIC, anon, authenticated'));
    expect(
      sql,
      contains(
        "'public.create_self_order(uuid,uuid,jsonb,text,text,text,uuid,integer)'::REGPROCEDURE",
      ),
    );
  });

  test('migration tidak mengubah token atau URL QR meja', () {
    expect(sql, isNot(contains('UPDATE public.restaurant_tables')));
    expect(sql, isNot(contains('SET qr_token')));
    expect(sql, isNot(contains('SET qr_code_url')));
  });

  test(
    'migration menghapus batas order aktif sambil mempertahankan kontrol outlet',
    () {
      expect(
        capacityLimitsSql,
        contains(
          'CREATE OR REPLACE FUNCTION public.enforce_self_order_enabled()',
        ),
      );
      expect(capacityLimitsSql, isNot(contains('self_order_max_active')));
      expect(capacityLimitsSql, contains('self_order_enabled'));
      expect(capacityLimitsSql, contains('self_order_schedule_enabled'));
    },
  );

  test('jumlah order QR dilepas tanpa membuka batas keamanan payload', () {
    expect(
      capacityLimitsSql,
      contains('Cooldown 15 detik tetap dipertahankan'),
    );
    expect(capacityLimitsSql, contains('public.enforce_order_item_limits()'));
    expect(
      capacityLimitsSql,
      contains("'public._self_order_line(uuid,jsonb)'::REGPROCEDURE"),
    );
    expect(capacityLimitsSql, contains('EXECUTE v_updated'));
    expect(capacityLimitsSql, contains("position('quantity'"));
    expect(capacityLimitsSql, contains("position('100'"));
    expect(capacityLimitsSql, contains("position('50'"));
    expect(capacityLimitsSql, contains("position('option_count'"));
    expect(capacityLimitsSql, contains("position('30'"));
    expect(capacityLimitsSql, contains('trg_enforce_order_item_limits'));
    expect(capacityLimitsSql, isNot(contains('2147483647')));
  });

  test('pengaturan cap dihapus dan tautan QR tidak disentuh', () {
    expect(onlineSettings, isNot(contains('self_order_max_active')));
    expect(onlineSettings, isNot(contains('_maxActiveCtrl')));
    expect(
      capacityLimitsSql,
      isNot(contains('UPDATE public.restaurant_tables')),
    );
    expect(capacityLimitsSql, isNot(contains('SET qr_token')));
    expect(capacityLimitsSql, isNot(contains('SET qr_code_url')));
  });
}

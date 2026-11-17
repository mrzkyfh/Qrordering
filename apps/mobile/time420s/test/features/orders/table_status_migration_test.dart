import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    '../../supabase/migrations/211_complete_table_status_sync.sql',
  ).readAsStringSync();

  test('order baru dan perubahan order sama-sama menyinkronkan status meja', () {
    expect(sql, contains('AFTER INSERT ON public.orders'));
    expect(sql, contains('AFTER UPDATE OF status, table_id ON public.orders'));
    expect(
      sql,
      contains(
        "NEW.status IN ('draft', 'confirmed', 'preparing', 'ready', 'served')",
      ),
    );
    expect(sql, contains("NEW.status IN ('paid', 'cancelled', 'void')"));
    expect(sql, contains('AFTER DELETE ON public.orders'));
  });

  test('rekonsiliasi hanya menulis status dan menjaga identitas QR', () {
    final reconciliation = sql.substring(
      sql.indexOf('-- Rekonsiliasi'),
      sql.indexOf('COMMENT ON FUNCTION'),
    );
    expect(reconciliation, contains("SET status = 'occupied'"));
    expect(reconciliation, contains("SET status = 'available'"));
    expect(reconciliation, contains("WHERE t.status = 'occupied'"));
    expect(reconciliation, isNot(contains('SET qr_token')));
    expect(reconciliation, isNot(contains('SET qr_code_url')));
    expect(reconciliation, isNot(contains('SET table_number')));
  });

  test('meja tidak bebas selama masih ada order aktif lain', () {
    expect(sql, contains('o.id <> NEW.id'));
    expect(sql, contains('NOT EXISTS'));
  });

  test('status reserved dan dirty tidak dibebaskan oleh rekonsiliasi', () {
    expect(sql, contains("WHERE t.status = 'occupied'"));
    expect(sql, isNot(contains("ELSE 'available'::public.table_status")));
  });
}

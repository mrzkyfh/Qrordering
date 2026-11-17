import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sales RPC uses exclusive filters and reconciled net totals', () {
    final sql = File(
      '../../supabase/migrations/183_fix_pos_sales_filters_and_totals.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains("lower(btrim(p_kind)) = 'dinein'"));
    expect(sql, contains("lower(btrim(p_kind)) = 'takeaway'"));
    expect(sql, contains("lower(btrim(p_kind)) = 'online'"));
    expect(sql, contains('max(p.paid_at)'));
    expect(sql, contains('source.sales_at >= p_date_from'));
    expect(sql, contains('source.sales_at < p_date_to'));
    expect(
      sql,
      contains('greatest(source.total_amount - source.refund_amount, 0)'),
    );
    expect(sql, contains('sum(net_total_amount)'));
  });

  test('sales RPC includes archived transactions and keeps cashier scope', () {
    final sql = File(
      '../../supabase/migrations/183_fix_pos_sales_filters_and_totals.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains('transaction_archive_orders'));
    expect(sql, contains('jsonb_array_elements'));
    expect(sql, contains('capture_archive_sales_facts'));
    expect(sql, contains('idx_archive_orders_outlet_sales'));
    expect(sql, contains('a.sales_at'));
    expect(sql, contains('a.refund_amount'));
    expect(sql, contains("public.auth_role()::text, '') <> 'kasir'"));
    expect(sql, contains('a.created_by = auth.uid()'));
    expect(sql, contains('o.created_by = auth.uid()'));
  });
}

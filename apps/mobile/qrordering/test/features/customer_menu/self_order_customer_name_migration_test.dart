import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    '../../supabase/migrations/213_respect_self_order_name_setting.sql',
  ).readAsStringSync();

  test('nama order QR hanya wajib saat setting outlet aktif', () {
    expect(
      sql,
      contains(
        'DROP CONSTRAINT IF EXISTS orders_self_order_customer_name_required',
      ),
    );
    expect(
      sql,
      contains("o.settings @> '{\"self_order_require_name\": true}'::JSONB"),
    );
    expect(sql, contains("NEW.order_type <> 'self_order'"));
    expect(sql, contains("NULLIF(BTRIM(NEW.customer_name), '') IS NULL"));
  });

  test('validasi tetap berjalan di level database untuk semua jalur tulis', () {
    expect(sql, contains('BEFORE INSERT ON public.orders'));
    expect(
      sql,
      contains(
        'BEFORE UPDATE OF order_type, customer_name, outlet_id ON public.orders',
      ),
    );
    expect(sql, contains('ERRCODE = \'23514\''));
  });
}

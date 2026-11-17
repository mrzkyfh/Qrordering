import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    '../../supabase/migrations/210_reliable_kitchen_print_claims.sql',
  ).readAsStringSync();

  test('klaim tiket dapur eksklusif juga untuk device yang sama', () {
    expect(sql, contains('claim_kitchen_print'));
    expect(sql, contains('kitchen_print_claim_expires_at'));
    expect(sql, contains("interval '10 minutes'"));
    expect(sql, contains('kitchen_print_claimed_by'));
    expect(sql, contains('kitchen_printed = false'));
    expect(
      sql,
      isNot(contains('OR o.kitchen_print_claimed_by = btrim(p_device_id)')),
    );
  });

  test('penyelesaian wajib dimiliki device pemegang lease', () {
    expect(sql, contains('complete_kitchen_print'));
    expect(
      sql,
      contains('DROP FUNCTION IF EXISTS public.record_kitchen_print(UUID)'),
    );
    expect(sql, contains('kitchen_printed = true'));
    expect(
      RegExp(
        r'complete_kitchen_print[\s\S]*?o\.kitchen_print_claimed_by = btrim\(p_device_id\)',
      ).hasMatch(sql),
      true,
    );
    expect(sql, contains('TO authenticated'));
    expect(sql, contains('FROM PUBLIC, anon'));
  });

  test('lease dapat diperpanjang, ditunda, dan dilepas', () {
    expect(sql, contains('renew_kitchen_print_claim'));
    expect(sql, contains('defer_kitchen_print_claim'));
    expect(sql, contains("interval '30 minutes'"));
    expect(sql, contains('release_kitchen_print_claim'));
  });

  test('edit order membersihkan klaim lama dan link QR tidak disentuh', () {
    expect(sql, contains('clear_stale_kitchen_print_claim'));
    expect(sql, contains('OLD.kitchen_printed = true'));
    expect(sql, contains('NEW.kitchen_printed = false'));
    expect(sql, isNot(contains('qr_token')));
    expect(sql, isNot(contains('qr_code_url')));
  });

  test('RPC dibatasi ke peran operasional aktif', () {
    expect(sql, contains("NOT IN ('owner', 'admin', 'manajer', 'kasir')"));
    expect(sql, contains("ERRCODE = '42501'"));
  });
}

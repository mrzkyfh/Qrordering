import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrordering/features/settings/data/app_settings.dart';
import 'package:qrordering/shared/services/local_receipt_number.dart';

/// Nomor struk lokal adalah satu-satunya rujukan yang dipegang pelanggan sampai
/// order tersinkron, jadi yang diuji di sini: nomor tidak pernah dipakai ulang
/// dalam satu hari, dan kode perangkat tidak berubah (kalau berubah, struk lama
/// jadi tak bisa dilacak).
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('local_receipt_no_test');
    Hive.init(tmp.path);
    await Hive.openBox(AppSettings.boxName);
    await Hive.box(AppSettings.boxName).clear();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('nomor urut naik & diformat 3 digit', () async {
    expect(await LocalReceiptNumber.next(), endsWith('-001'));
    expect(await LocalReceiptNumber.next(), endsWith('-002'));
    expect(await LocalReceiptNumber.next(), endsWith('-003'));
  });

  test('kode perangkat menetap antar-nomor & antar-restart', () async {
    final first = (await LocalReceiptNumber.next()).split('-').first;
    await LocalReceiptNumber.next();
    final second = (await LocalReceiptNumber.next()).split('-').first;
    expect(second, first, reason: 'kode device tidak boleh berubah saat dipakai');

    // Simulasi restart aplikasi: box ditutup lalu dibuka lagi dari disk.
    await Hive.close();
    Hive.init(tmp.path);
    await Hive.openBox(AppSettings.boxName);
    expect(LocalReceiptNumber.deviceCode, first,
        reason: 'kode device dibaca dari disk, bukan di-generate ulang');
  });

  test('kode perangkat 2 karakter tanpa huruf/angka yang rancu didikte',
      () async {
    final code = LocalReceiptNumber.deviceCode;
    expect(code.length, 2);
    // 0/O, 1/I, 5/S sengaja dihindari — nomor ini dibaca dari kertas termal.
    expect(code, isNot(matches(RegExp(r'[01O5IS]'))));
  });

  test('counter reset saat hari berganti', () async {
    await LocalReceiptNumber.next();
    await LocalReceiptNumber.next();
    final code = LocalReceiptNumber.deviceCode;

    // Mundurkan tanggal tersimpan → seolah nomor terakhir dibuat kemarin.
    await Hive.box(AppSettings.boxName).put('receipt_seq_date', '2020-01-01');

    expect(await LocalReceiptNumber.next(), '$code-001',
        reason: 'hari baru mulai dari 001 lagi');
  });

  test('nomor tidak dipakai ulang setelah restart di hari yang sama', () async {
    await LocalReceiptNumber.next(); // 001
    await LocalReceiptNumber.next(); // 002

    await Hive.close();
    Hive.init(tmp.path);
    await Hive.openBox(AppSettings.boxName);

    expect(await LocalReceiptNumber.next(), endsWith('-003'),
        reason: 'counter dibaca dari disk — restart tak boleh mengulang 001');
  });
}

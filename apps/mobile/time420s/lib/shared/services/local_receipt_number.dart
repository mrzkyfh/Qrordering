import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';
import '../../features/settings/data/app_settings.dart';

/// Penomor struk LOKAL per perangkat.
///
/// Sejak struk dicetak sebelum order sampai ke server, `order_number` (atomik,
/// dari `get_next_order_number`) belum ada saat kertas keluar. Nomor lokal
/// mengisi kekosongan itu supaya struk pelanggan tetap punya rujukan yang bisa
/// didikte saat komplain — nilainya ikut dikirim ke kolom `orders.local_receipt_no`
/// saat sync (lihat migration 112).
///
/// Format: `{kodeDevice}-{urut}` mis. `A7-014`.
/// - kodeDevice: 2 karakter, di-generate sekali per instalasi lalu menetap.
///   Membedakan struk antar-HP di outlet yang sama tanpa koordinasi server —
///   penting karena tiap HP menomori sendiri dan pasti bertabrakan tanpa prefiks.
/// - urut: reset tiap hari (waktu lokal perangkat = waktu yang dilihat kasir),
///   3 digit agar mudah dibaca; melewati 999 tetap dicetak apa adanya (1000).
///
/// BUKAN pengganti `order_number`: tidak unik lintas perangkat dan tidak dijamin
/// tanpa lompatan (nomor terpakai saat cetak, walau transaksi berakhir di
/// dead-letter). Perannya petunjuk pencarian, bukan identitas.
class LocalReceiptNumber {
  LocalReceiptNumber._();

  static const _kDeviceCode = 'device_code';
  static const _kSeqDate = 'receipt_seq_date';
  static const _kSeq = 'receipt_seq';

  // Tanpa huruf/angka yang mudah tertukar saat didikte lewat telepon
  // (0/O, 1/I, 5/S) — nomor ini dibaca dari kertas termal yang sering pudar.
  static const _alphabet = 'ACDEFHJKLMNPQRTUVWXY2346789';

  static Box get _box => Hive.box(AppSettings.boxName);

  /// Kode perangkat, dibuat saat pertama dipakai lalu tetap selamanya.
  static String get deviceCode {
    final existing = _box.get(_kDeviceCode) as String?;
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final code = List.generate(2, (_) => _alphabet[rnd.nextInt(_alphabet.length)])
        .join();
    _box.put(_kDeviceCode, code);
    return code;
  }

  /// Ambil nomor struk berikutnya & simpan counternya.
  ///
  /// Menaikkan counter walau struk gagal tercetak: lebih baik ada nomor yang
  /// terlewat daripada dua struk berbeda memakai nomor yang sama.
  static Future<String> next() async {
    final today = _todayKey();
    final lastDate = _box.get(_kSeqDate) as String?;
    final seq = (lastDate == today ? (_box.get(_kSeq) as int? ?? 0) : 0) + 1;
    await _box.put(_kSeqDate, today);
    await _box.put(_kSeq, seq);
    return '$deviceCode-${seq.toString().padLeft(3, '0')}';
  }

  /// Tanggal lokal perangkat (bukan UTC): counter harus berganti saat hari
  /// berganti menurut kasir, bukan menurut UTC yang meleset 7 jam dari WIB.
  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}

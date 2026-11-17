import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Batas maksimum staf boleh melanjutkan operasi POS tanpa verifikasi server.
///
/// Cache data lain boleh berumur lebih panjang, tetapi otorisasi untuk menerima
/// Otorisasi berlaku sepanjang satu hari operasional. Dengan ini gangguan Wi-Fi
/// tidak mengeluarkan kasir setiap 15 menit, tetapi akun tetap wajib mendapat
/// verifikasi server atau clock-in PIN offline lagi pada hari berikutnya.
const staffAuthorizationLeaseDuration = Duration(hours: 24);

@visibleForTesting
bool isStaffAuthorizationLeaseValid({
  required DateTime? authorizedAt,
  DateTime? now,
  Duration maxAge = staffAuthorizationLeaseDuration,
}) {
  if (authorizedAt == null) return false;
  final current = (now ?? DateTime.now()).toUtc();
  final issued = authorizedAt.toUtc();
  final age = current.difference(issued);
  // Jam perangkat yang mundur tidak boleh memperpanjang lease tanpa batas.
  return !age.isNegative && age <= maxAge;
}

class StaffAuthorizationLease {
  StaffAuthorizationLease._();

  static const boxName = 'menu_cache_secure_v1';
  static const _keyPrefix = 'staff_auth_lease_';

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  static String _key(String userId) => '$_keyPrefix$userId';

  static Future<bool> grant(String userId, {DateTime? now}) async {
    final box = _box;
    if (box == null || userId.isEmpty) return false;
    await box.put(
      _key(userId),
      (now ?? DateTime.now()).toUtc().toIso8601String(),
    );
    return true;
  }

  static bool isValid(String userId, {DateTime? now}) {
    final raw = _box?.get(_key(userId));
    final issued = raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    return isStaffAuthorizationLeaseValid(authorizedAt: issued, now: now);
  }

  static DateTime? expiresAt(String userId) {
    final raw = _box?.get(_key(userId));
    final issued = raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    return issued?.add(staffAuthorizationLeaseDuration);
  }

  static Future<void> revoke(String userId) async {
    final box = _box;
    if (box == null || userId.isEmpty) return;
    await box.delete(_key(userId));
    // Profil dan lease harus gugur bersama. Ini mencegah cache profil aktif
    // lama dipakai ulang setelah server sudah mengembalikan is_active=false.
    await box.delete('auth_profile_$userId');
  }
}

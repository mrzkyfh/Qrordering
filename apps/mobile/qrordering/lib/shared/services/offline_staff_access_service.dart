import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/pos/data/datasources/pos_datasource.dart';
import '../models/enums.dart';
import '../models/profile.dart';

class OfflineStaffAccessLockedException implements Exception {
  const OfflineStaffAccessLockedException(this.retryAfterMinutes);

  final int retryAfterMinutes;

  @override
  String toString() =>
      'PIN offline terkunci. Coba lagi dalam $retryAfterMinutes menit atau sambungkan internet.';
}

/// Kredensial lokal terbatas untuk clock-in ketika cabang kehilangan internet.
///
/// Verifier PIN dan profil berada di box Hive AES-256. PIN asli tidak pernah
/// disimpan. Akses harus pernah diverifikasi server pada perangkat ini dan
/// otomatis kedaluwarsa agar akun yang lama tidak aktif tidak berlaku abadi.
class OfflineStaffAccessService {
  OfflineStaffAccessService._();
  static final OfflineStaffAccessService instance =
      OfflineStaffAccessService._();

  static const validity = Duration(days: 7);
  static const _keyPrefix = 'offline_staff_access_v1_';
  static const _iterations = 20000;
  static const _maxPinFailures = 5;
  static const _pinLockoutDuration = Duration(minutes: 15);

  Box<dynamic>? get _box => Hive.isBoxOpen(PosDatasource.menuCacheBoxName)
      ? Hive.box<dynamic>(PosDatasource.menuCacheBoxName)
      : null;

  String _key(String outletId, String staffId) =>
      '$_keyPrefix${outletId}_$staffId';

  Future<void> remember({
    required String outletId,
    required Profile profile,
    required String pin,
  }) async {
    final box = _box;
    if (box == null || outletId.isEmpty || profile.id.isEmpty || pin.isEmpty) {
      return;
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final verifier = _derive(pin, salt);
    await box.put(
      _key(outletId, profile.id),
      jsonEncode({
        'salt': base64UrlEncode(salt),
        'verifier': base64UrlEncode(verifier),
        'verified_at': DateTime.now().toUtc().toIso8601String(),
        'profile': {
          'id': profile.id,
          'outlet_id': profile.outletId ?? outletId,
          'outlet_name': profile.outletName,
          'role': profile.role.value,
          'full_name': profile.fullName,
          'phone': profile.phone,
          'avatar_url': profile.avatarUrl,
          'is_active': profile.isActive,
          'can_refund': profile.canRefund,
          'last_login_at': profile.lastLoginAt?.toUtc().toIso8601String(),
          'created_at': profile.createdAt.toUtc().toIso8601String(),
          'updated_at': profile.updatedAt.toUtc().toIso8601String(),
        },
      }),
    );
  }

  Future<Profile?> authenticate({
    required String outletId,
    required String staffId,
    required String pin,
    DateTime? now,
  }) async {
    final box = _box;
    final key = _key(outletId, staffId);
    final raw = box?.get(key) as String?;
    if (raw == null) return null;
    try {
      final record = jsonDecode(raw) as Map<String, dynamic>;
      final verifiedAt = DateTime.parse(
        record['verified_at'] as String,
      ).toUtc();
      final current = (now ?? DateTime.now()).toUtc();
      final age = current.difference(verifiedAt);
      if (age.isNegative || age > validity) return null;

      final lockedUntilValue = record['locked_until'];
      if (lockedUntilValue is String) {
        final lockedUntil = DateTime.tryParse(lockedUntilValue)?.toUtc();
        if (lockedUntil == null) return null;
        if (current.isBefore(lockedUntil)) {
          throw _lockoutException(lockedUntil, current);
        }
        record['failed_attempts'] = 0;
        record['locked_until'] = null;
      }

      final salt = base64Url.decode(record['salt'] as String);
      final expected = base64Url.decode(record['verifier'] as String);
      final actual = _derive(pin, salt);
      if (!_constantTimeEquals(actual, expected)) {
        final failures =
            ((record['failed_attempts'] as num?)?.toInt() ?? 0) + 1;
        if (failures >= _maxPinFailures) {
          final lockedUntil = current.add(_pinLockoutDuration);
          record['failed_attempts'] = failures;
          record['locked_until'] = lockedUntil.toIso8601String();
          await box!.put(key, jsonEncode(record));
          throw _lockoutException(lockedUntil, current);
        }
        record['failed_attempts'] = failures;
        await box!.put(key, jsonEncode(record));
        return null;
      }

      final profile = Profile.fromJson(
        Map<String, dynamic>.from(record['profile'] as Map),
      );
      if (!profile.isActive || profile.id != staffId) return null;
      final profileOutlet = profile.outletId;
      if (profileOutlet != null &&
          profileOutlet.isNotEmpty &&
          profileOutlet != outletId) {
        return null;
      }
      if (record['failed_attempts'] != 0 || record['locked_until'] != null) {
        record['failed_attempts'] = 0;
        record['locked_until'] = null;
        await box!.put(key, jsonEncode(record));
      }
      return profile;
    } on OfflineStaffAccessLockedException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  OfflineStaffAccessLockedException _lockoutException(
    DateTime lockedUntil,
    DateTime current,
  ) {
    final retryAfterMinutes = (lockedUntil.difference(current).inSeconds / 60)
        .ceil();
    return OfflineStaffAccessLockedException(retryAfterMinutes.clamp(1, 15));
  }

  Future<void> revoke(String outletId, String staffId) async {
    await _box?.delete(_key(outletId, staffId));
  }

  Iterable<String> staffIds() sync* {
    final box = _box;
    if (box == null) return;
    for (final key in box.keys.whereType<String>()) {
      if (!key.startsWith(_keyPrefix)) continue;
      try {
        final record = jsonDecode(box.get(key) as String) as Map;
        final profile = record['profile'] as Map;
        final id = profile['id'] as String?;
        if (id != null && id.isNotEmpty) yield id;
      } catch (_) {
        // Record rusak akan diabaikan dan tidak pernah dapat diautentikasi.
      }
    }
  }

  Future<void> clearAll() async {
    final box = _box;
    if (box == null) return;
    final keys = box.keys
        .whereType<String>()
        .where((key) => key.startsWith(_keyPrefix))
        .toList();
    await box.deleteAll(keys);
  }

  List<int> _derive(String pin, List<int> salt) {
    var block = <int>[...utf8.encode(pin), ...salt];
    for (var i = 0; i < _iterations; i++) {
      block = sha256.convert(<int>[...block, ...salt]).bytes;
    }
    return block;
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}

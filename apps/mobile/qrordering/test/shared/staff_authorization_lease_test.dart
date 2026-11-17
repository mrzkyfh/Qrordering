import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrordering/shared/services/staff_authorization_lease.dart';

void main() {
  group('isStaffAuthorizationLeaseValid', () {
    final now = DateTime.utc(2026, 8, 30, 12);

    test('menerima otorisasi yang masih di dalam satu hari operasional', () {
      expect(
        isStaffAuthorizationLeaseValid(
          authorizedAt: now.subtract(const Duration(hours: 23)),
          now: now,
        ),
        isTrue,
      );
    });

    test('menolak otorisasi kedaluwarsa dan timestamp dari masa depan', () {
      expect(
        isStaffAuthorizationLeaseValid(
          authorizedAt: now.subtract(const Duration(hours: 25)),
          now: now,
        ),
        isFalse,
      );
      expect(
        isStaffAuthorizationLeaseValid(
          authorizedAt: now.add(const Duration(minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('StaffAuthorizationLease storage', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('staff_auth_lease_test');
      Hive.init(temp.path);
      await Hive.openBox(StaffAuthorizationLease.boxName);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await temp.delete(recursive: true);
    });

    test('grant dan revoke ikut menghapus cache profil staf', () async {
      final box = Hive.box(StaffAuthorizationLease.boxName);
      await box.put('auth_profile_staff-1', 'cached-profile');
      await StaffAuthorizationLease.grant(
        'staff-1',
        now: DateTime.utc(2026, 8, 30, 12),
      );

      expect(
        StaffAuthorizationLease.isValid(
          'staff-1',
          now: DateTime.utc(2026, 8, 30, 12, 10),
        ),
        isTrue,
      );

      await StaffAuthorizationLease.revoke('staff-1');
      expect(StaffAuthorizationLease.isValid('staff-1'), isFalse);
      expect(box.containsKey('auth_profile_staff-1'), isFalse);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/profile.dart';
import 'package:time420s/shared/services/offline_staff_access_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  final profile = Profile(
    id: 'staff-1',
    outletId: 'outlet-1',
    role: UserRole.kasir,
    fullName: 'Budi Kasir',
    isActive: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('offline_staff_test');
    Hive.init(temp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await temp.delete(recursive: true);
  });

  test('PIN benar membuka profil lokal, PIN salah ditolak', () async {
    await OfflineStaffAccessService.instance.remember(
      outletId: 'outlet-1',
      profile: profile,
      pin: '1234',
    );

    expect(
      await OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
      ),
      profile,
    );
    expect(
      await OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '0000',
      ),
      isNull,
    );
  });

  test('verifikasi lama dan outlet berbeda ditolak', () async {
    final verifiedAt = DateTime.now().toUtc();
    await OfflineStaffAccessService.instance.remember(
      outletId: 'outlet-1',
      profile: profile,
      pin: '1234',
    );
    final box = Hive.box(PosDatasource.menuCacheBoxName);
    final key = box.keys.whereType<String>().single;
    final raw = box.get(key) as String;
    // Waktu kedaluwarsa diuji lewat parameter now tanpa bergantung jam mesin.
    expect(
      await OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
        now: verifiedAt.add(const Duration(days: 8)),
      ),
      isNull,
    );
    expect(raw, isNot(contains('1234')));
    expect(
      await OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-2',
        staffId: 'staff-1',
        pin: '1234',
      ),
      isNull,
    );
  });

  test('lima PIN salah mengunci akses sampai cooldown berakhir', () async {
    await OfflineStaffAccessService.instance.remember(
      outletId: 'outlet-1',
      profile: profile,
      pin: '1234',
    );
    final now = DateTime.now().toUtc().add(const Duration(seconds: 1));

    for (var attempt = 0; attempt < 4; attempt++) {
      expect(
        await OfflineStaffAccessService.instance.authenticate(
          outletId: 'outlet-1',
          staffId: 'staff-1',
          pin: '0000',
          now: now,
        ),
        isNull,
      );
    }
    await expectLater(
      OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '0000',
        now: now,
      ),
      throwsA(isA<OfflineStaffAccessLockedException>()),
    );

    await Hive.box(PosDatasource.menuCacheBoxName).close();
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await expectLater(
      OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
        now: now,
      ),
      throwsA(isA<OfflineStaffAccessLockedException>()),
    );
    expect(
      await OfflineStaffAccessService.instance.authenticate(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
        now: now.add(const Duration(minutes: 16)),
      ),
      profile,
    );
  });
}

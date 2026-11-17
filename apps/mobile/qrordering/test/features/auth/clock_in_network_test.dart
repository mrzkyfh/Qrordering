import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/models/profile.dart';
import 'package:qrordering/shared/services/connectivity_service.dart';
import 'package:qrordering/shared/services/offline_staff_access_service.dart';
import 'package:qrordering/shared/services/supabase_service.dart';
import 'package:qrordering/shared/services/staff_authorization_lease.dart';

class _FakeClockInApi {
  final paths = <String>[];
  late final HttpServer _server;
  bool _stopped = false;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      await utf8.decoder.bind(request).join();
      paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_reply(request)));
      await request.response.close();
    });
  }

  Object? _reply(HttpRequest request) {
    if (request.uri.path == '/rest/v1/rpc/touch_device_heartbeat') {
      return null;
    }
    if (request.uri.path == '/functions/v1/clock-in') {
      return {
        'refresh_token': 'refresh-from-clock-in',
        'profile': {
          'id': 'staff-1',
          'outlet_id': 'outlet-1',
          'full_name': 'Budi Kasir',
          'role': 'kasir',
          'is_active': true,
        },
      };
    }
    if (request.uri.path == '/auth/v1/token') {
      return {
        'access_token': _jwt('staff-1'),
        'refresh_token': 'refresh-staff-session',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': 'staff-1',
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': 'staff@example.test',
          'created_at': '2026-07-27T00:00:00Z',
          'updated_at': '2026-07-27T00:00:00Z',
        },
      };
    }
    return {};
  }

  String _jwt(String userId) {
    String part(Map<String, Object> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiresAt =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${part({'sub': userId, 'aud': 'authenticated', 'role': 'authenticated', 'exp': expiresAt})}.signature';
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeClockInApi api;
  late Directory temp;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('clock_in_network_test');
    Hive.init(temp.path);
    await Hive.openBox(StaffAuthorizationLease.boxName);
    ConnectivityService.instance.online.value = true;
    api = _FakeClockInApi();
    await api.start();
    await Supabase.initialize(
      url: api.url,
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = true;
    await Supabase.instance.dispose();
    await api.stop();
    await Hive.deleteFromDisk();
    await temp.delete(recursive: true);
  });

  test('heartbeat hanya untuk sesi akun perangkat yang tersimpan', () {
    expect(shouldSendDeviceHeartbeat('device-1', 'device-1'), isTrue);
    expect(shouldSendDeviceHeartbeat('staff-1', 'device-1'), isFalse);
    expect(shouldSendDeviceHeartbeat('staff-1', null), isFalse);
    expect(shouldSendDeviceHeartbeat(null, 'device-1'), isFalse);
  });

  test('heartbeat perangkat ditahan 15 menit termasuk setelah gagal', () {
    final now = DateTime.utc(2026, 10, 3, 8);
    expect(deviceHeartbeatIsDue(null, now), isTrue);
    expect(
      deviceHeartbeatIsDue(now.subtract(const Duration(minutes: 14)), now),
      isFalse,
    );
    expect(
      deviceHeartbeatIsDue(now.subtract(const Duration(minutes: 15)), now),
      isTrue,
    );
    expect(deviceHeartbeatIsDue(now, now, force: true), isTrue);
  });

  test('izin perangkat offline dibatasi tujuh hari dan menolak jam mundur', () {
    final now = DateTime.utc(2026, 10, 4, 12);
    expect(deviceOfflineAuthorizationIsValid(null, now), isFalse);
    expect(
      deviceOfflineAuthorizationIsValid(
        now.subtract(const Duration(days: 7)),
        now,
      ),
      isTrue,
    );
    expect(
      deviceOfflineAuthorizationIsValid(
        now.subtract(const Duration(days: 7, seconds: 1)),
        now,
      ),
      isFalse,
    );
    expect(
      deviceOfflineAuthorizationIsValid(
        now.add(const Duration(minutes: 1)),
        now,
      ),
      isFalse,
    );
  });

  test('login perangkat menolak Admin dan menerima akun perangkat valid', () {
    Profile makeProfile({
      UserRole role = UserRole.pelanggan,
      bool isActive = true,
      String? outletId = 'outlet-1',
      String id = 'device-1',
    }) => Profile(
      id: id,
      outletId: outletId,
      role: role,
      fullName: 'Perangkat Cabang',
      isActive: isActive,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    expect(isValidDeviceLoginProfile(makeProfile(), 'device-1'), isTrue);
    expect(
      isValidDeviceLoginProfile(makeProfile(role: UserRole.admin), 'device-1'),
      isFalse,
    );
    expect(
      isValidDeviceLoginProfile(makeProfile(isActive: false), 'device-1'),
      isFalse,
    );
    expect(
      isValidDeviceLoginProfile(makeProfile(outletId: null), 'device-1'),
      isFalse,
    );
    expect(isValidDeviceLoginProfile(makeProfile(), 'other-user'), isFalse);
  });

  test(
    'clock-in memakai satu pertukaran sesi tanpa request getUser tambahan',
    () async {
      final profile = await SupabaseService().clockIn(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
      );

      expect(profile.id, 'staff-1');
      expect(Supabase.instance.client.auth.currentUser?.id, 'staff-1');
      expect(api.paths.where((path) => path == '/auth/v1/token'), hasLength(1));
      expect(
        api.paths.where((path) => path == '/auth/v1/user'),
        isEmpty,
        reason:
            'setSession sudah diverifikasi Auth server; getUser berulang '
            'hanya menambah latensi PIN.',
      );
    },
  );

  test(
    'indikator online stale fallback ke PIN lokal saat backend putus',
    () async {
      final box = Hive.box(PosDatasource.menuCacheBoxName);
      for (final key in const [
        'cat_outlet-1',
        'item_outlet-1',
        'open_shifts_outlet-1',
        'orders_active_outlet-1',
        'orders_completed_outlet-1',
        'tables_outlet-1',
        'clockin_staff_outlet-1',
      ]) {
        await box.put(key, jsonEncode(const []));
      }
      for (final key in const [
        'settings_outlet-1',
        'receipt_outlet_outlet-1',
        'catnames_outlet-1',
      ]) {
        await box.put(key, jsonEncode(const {}));
      }
      await box.put('offline_bundle_ready_outlet-1', true);
      final profile = Profile(
        id: 'staff-1',
        outletId: 'outlet-1',
        role: UserRole.kasir,
        fullName: 'Budi Kasir',
        isActive: true,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await OfflineStaffAccessService.instance.remember(
        outletId: 'outlet-1',
        profile: profile,
        pin: '1234',
      );
      // Simulasikan Wi-Fi masih terdeteksi aktif tepat ketika backend mati.
      ConnectivityService.instance.online.value = true;
      await api.stop();

      final restored = await SupabaseService().clockIn(
        outletId: 'outlet-1',
        staffId: 'staff-1',
        pin: '1234',
      );

      expect(restored, profile);
      expect(StaffAuthorizationLease.isValid('staff-1'), isTrue);
    },
  );
}

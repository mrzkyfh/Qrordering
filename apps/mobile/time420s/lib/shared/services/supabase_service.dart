import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/enums.dart';
import '../models/profile.dart';
import 'connectivity_service.dart';
import 'backend_request.dart';
import 'offline_bootstrap_service.dart';
import 'offline_staff_access_service.dart';
import 'staff_authorization_lease.dart';
import '../../core/startup/startup_support.dart';

/// Kolom profil yang aman untuk aplikasi. Jangan kembali memakai `*`:
/// `profiles.pin_hash` dan metadata kegagalan PIN sengaja tidak dapat dibaca
/// role authenticated, sehingga wildcard membuat seluruh query profil gagal.
const profileSelectColumns =
    'id, outlet_id, role, full_name, phone, avatar_url, is_active, '
    'can_refund, last_login_at, created_at, updated_at, outlets(name)';
const _authRestoreRequestTimeout = Duration(seconds: 12);
const _secureStorageStartupTimeout = Duration(seconds: 8);

@visibleForTesting
bool shouldSendDeviceHeartbeat(String? sessionUserId, String? deviceUserId) =>
    sessionUserId != null && sessionUserId == deviceUserId;

bool isValidDeviceLoginProfile(Profile? profile, String authUserId) =>
    profile != null &&
    profile.id == authUserId &&
    profile.role == UserRole.pelanggan &&
    profile.isActive &&
    profile.outletId?.isNotEmpty == true;

const deviceHeartbeatMinInterval = Duration(minutes: 15);
const deviceOfflineAuthorizationValidity = Duration(days: 7);

@visibleForTesting
bool deviceHeartbeatIsDue(
  DateTime? lastAttempt,
  DateTime now, {
  bool force = false,
}) {
  if (force || lastAttempt == null || now.isBefore(lastAttempt)) return true;
  return now.difference(lastAttempt) >= deviceHeartbeatMinInterval;
}

@visibleForTesting
bool deviceOfflineAuthorizationIsValid(
  DateTime? verifiedAt,
  DateTime now, {
  Duration maxAge = deviceOfflineAuthorizationValidity,
}) {
  if (verifiedAt == null) return false;
  final age = now.toUtc().difference(verifiedAt.toUtc());
  return !age.isNegative && age <= maxAge;
}

/// Bentuk profil dari respons edge function clock-in.
///
/// Respons ini sudah dihasilkan setelah PIN diverifikasi oleh server. Memakai
/// data tersebut menghindari query profil kedua yang dapat terlambat sesaat
/// setelah sesi berubah dari akun perangkat menjadi akun staf.
Profile clockInProfileFromPayload(Object? payload, {required String staffId}) {
  if (payload is! Map) {
    throw Exception('Gagal clock-in: respons server tidak valid');
  }
  if (payload['error'] != null) {
    throw Exception(payload['error'].toString());
  }

  final rawProfile = payload['profile'];
  if (rawProfile is! Map) {
    throw Exception('Gagal clock-in: data staf tidak diterima');
  }

  final id = rawProfile['id'] as String?;
  final fullName = rawProfile['full_name'] as String?;
  final role = rawProfile['role'] as String?;
  if (id == null ||
      id != staffId ||
      fullName == null ||
      fullName.trim().isEmpty ||
      role == null ||
      role.isEmpty) {
    throw Exception('Gagal clock-in: data staf tidak lengkap');
  }

  final now = DateTime.now();
  return Profile(
    id: id,
    outletId: rawProfile['outlet_id'] as String?,
    outletName: rawProfile['outlet_name'] as String?,
    role: UserRoleX.fromString(role),
    fullName: fullName,
    // Field status wajib fail-closed. Respons lama/tidak lengkap tidak boleh
    // mengubah ketiadaan bukti aktif menjadi izin menjalankan POS.
    isActive: rawProfile['is_active'] as bool? ?? false,
    // Nilai aman untuk respons edge function versi lama. Hak refund tetap
    // diperiksa server; versi function terbaru mengirim nilai sebenarnya.
    canRefund: rawProfile['can_refund'] as bool? ?? false,
    lastLoginAt: _parseOptionalDate(rawProfile['last_login_at']),
    createdAt: _parseOptionalDate(rawProfile['created_at']) ?? now,
    updatedAt: _parseOptionalDate(rawProfile['updated_at']) ?? now,
  );
}

DateTime? _parseOptionalDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

/// Kredensial perangkat harus lengkap. Versi lama hanya memeriksa email,
/// sehingga secure storage yang terpotong dapat mengarahkan pengguna ke layar
/// clock-in meskipun password untuk memulihkan sesi sebenarnya sudah hilang.
@visibleForTesting
bool hasCompleteDeviceCredentials(String? email, String? password) {
  return email?.trim().isNotEmpty == true &&
      password?.trim().isNotEmpty == true;
}

class SupabaseService {
  final _client = Supabase.instance.client;
  // Device credentials survive process termination and app updates. Android
  // clears this encrypted storage when app data is cleared or the app is
  // uninstalled (backup is disabled in AndroidManifest.xml).
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kDevEmail = 'device_email';
  static const _kDevPass = 'device_password';
  static const _kDevUserId = 'device_user_id';
  static const _kDevOutletId = 'device_outlet_id';
  static const _kDevVerifiedAt = 'device_verified_at';
  static const _kDevHeartbeatAttemptAt = 'device_heartbeat_attempt_at';
  static const _kOfflineActiveStaffId = 'offline_active_staff_id';
  static const _kStaffRefreshPrefix = 'staff_refresh_token_';
  static Future<void>? _heartbeatInFlight;

  Future<String?> _readSecureForStartup(String key) =>
      runStartupOperation<String?>(
        category: 'SECURE_STORAGE_TIMEOUT',
        timeout: _secureStorageStartupTimeout,
        operation: () => _storage.read(key: key),
      );

  Future<void> _writeSecureForStartup(String key, String value) =>
      runStartupOperation<void>(
        category: 'SECURE_STORAGE_TIMEOUT',
        timeout: _secureStorageStartupTimeout,
        operation: () => _storage.write(key: key, value: value),
      );

  /// Identitas staf yang harus menjadi pemilik mutasi. Saat clock-in offline,
  /// JWT masih dapat berupa akun perangkat sehingga `auth.currentUser` bukan
  /// sumber identitas yang benar untuk payload outbox.
  Future<String?> activeStaffIdForMutation() async {
    try {
      final offlineStaff = await _storage.read(key: _kOfflineActiveStaffId);
      if (offlineStaff?.trim().isNotEmpty == true) return offlineStaff!.trim();
    } catch (_) {
      // Sesi Supabase di bawah tetap dapat digunakan untuk clock-in online.
    }
    return _client.auth.currentUser?.id;
  }

  Future<Profile?> getProfile(
    String userId, {
    bool allowCachedFallback = true,
  }) async {
    final cache = Hive.isBoxOpen('menu_cache_secure_v1')
        ? Hive.box('menu_cache_secure_v1')
        : null;
    final cacheKey = 'auth_profile_$userId';
    Map<String, dynamic>? data;
    try {
      data = await _client
          .from('profiles')
          .select(profileSelectColumns)
          .eq('id', userId)
          .maybeSingle()
          .timeout(_authRestoreRequestTimeout);
    } catch (networkError, stackTrace) {
      // Login/pemulihan akun perangkat adalah batas otorisasi. Pada jalur itu
      // role dari cache tidak boleh menggantikan keputusan server karena akun
      // mungkin sudah dinonaktifkan atau diubah menjadi Admin.
      if (!allowCachedFallback) {
        Error.throwWithStackTrace(networkError, stackTrace);
      }
      final raw = cache?.get(cacheKey) as String?;
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          final cachedAt = DateTime.tryParse(
            decoded['cached_at'] as String? ?? '',
          )?.toUtc();
          final profile = decoded['profile'];
          if (cachedAt != null && profile is Map) {
            final cachedProfile = Profile.fromJson(
              Map<String, dynamic>.from(profile),
            );
            if (!cachedProfile.isActive) {
              await StaffAuthorizationLease.revoke(userId);
            } else if (StaffAuthorizationLease.isValid(userId)) {
              return cachedProfile;
            }
          }
        } catch (_) {
          // Cache rusak/tidak kompatibel tidak boleh menutupi error server.
        }
      }
      Error.throwWithStackTrace(networkError, stackTrace);
    }

    if (data == null) return null;
    final profile = Profile.fromJson(data);
    if (!profile.isActive) {
      try {
        await StaffAuthorizationLease.revoke(userId);
      } catch (_) {
        // Status server tetap otoritatif meskipun pembersihan cache gagal.
      }
      return profile;
    }
    try {
      await cache?.put(
        cacheKey,
        jsonEncode({
          'cached_at': DateTime.now().toUtc().toIso8601String(),
          'profile': data,
        }),
      );
      await StaffAuthorizationLease.grant(userId);
    } catch (_) {
      // Profil online tetap sah; kegagalan cache membuat pembayaran fail-closed
      // karena lease tidak akan tersedia.
    }
    // Migrasi aman untuk instalasi lama: bila sesi yang sedang aktif memang
    // sama dengan akun perangkat tersimpan dan profil server baru saja sukses
    // dibaca, buat/perbarui bukti offline. Ini tidak pernah dijalankan dari
    // hasil cache maupun saat Admin sekadar melihat profil akun lain.
    if (isValidDeviceLoginProfile(profile, userId) &&
        _client.auth.currentUser?.id == userId &&
        await storedDeviceUserId == userId) {
      try {
        await _persistDeviceOutlet(profile);
        await _storage.write(
          key: _kDevVerifiedAt,
          value: DateTime.now().toUtc().toIso8601String(),
        );
      } catch (_) {
        // Profil online tetap dapat dipakai; hanya fallback offline yang tidak
        // aktif bila secure storage perangkat gagal ditulis.
      }
    }
    return profile;
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  /// Daftar outlet untuk picker clock-in (anon-readable).
  Future<List<Map<String, dynamic>>> listOutlets() async {
    final rows = await _client.from('outlets').select('id, name').order('name');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Daftar staff aktif sebuah outlet untuk layar clock-in.
  /// Hanya {id, full_name, role, has_pin} — tidak ada data sensitif.
  Future<List<Map<String, dynamic>>> listClockinStaff(String outletId) async {
    final key = 'clockin_staff_$outletId';
    final cache = Hive.isBoxOpen('menu_cache_secure_v1')
        ? Hive.box('menu_cache_secure_v1')
        : null;
    try {
      final rows = await _client.rpc(
        'list_clockin_staff',
        params: {'p_outlet': outletId},
      );
      final result = (rows as List)
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      await cache?.put(key, jsonEncode(result));
      return result;
    } catch (_) {
      final raw = cache?.get(key) as String?;
      if (raw != null) {
        return (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      }
      rethrow;
    }
  }

  /// Clock-in: tukar PIN → session staff via edge function `clock-in`.
  Future<Profile> clockIn({
    required String outletId,
    required String staffId,
    required String pin,
  }) async {
    if (!ConnectivityService.instance.online.value) {
      return _clockInOffline(outletId: outletId, staffId: staffId, pin: pin);
    }
    await touchDeviceHeartbeat();
    FunctionResponse res;
    try {
      res = await _client.functions.invoke(
        'clock-in',
        body: {'outlet_id': outletId, 'staff_id': staffId, 'pin': pin},
      );
    } catch (error) {
      // Status koneksi OS dapat tertinggal beberapa detik: Wi-Fi masih aktif
      // tetapi internet/backend sudah putus. Hanya kegagalan transport/5xx
      // yang boleh fallback; PIN salah/akun terkunci (4xx) tetap otoritatif.
      if (!isBackendTemporarilyUnavailable(error)) rethrow;
      return _clockInOffline(outletId: outletId, staffId: staffId, pin: pin);
    }
    final data = res.data;
    // Validasi profil sebelum menukar sesi agar kegagalan respons tidak
    // meninggalkan aplikasi dalam keadaan setengah login.
    final profile = clockInProfileFromPayload(data, staffId: staffId);
    if (!profile.isActive) {
      try {
        await StaffAuthorizationLease.revoke(staffId);
      } catch (_) {
        // Respons server nonaktif tetap harus ditolak walau cache bermasalah.
      }
      throw Exception('Akun staf dinonaktifkan');
    }
    final refresh = (data is Map) ? data['refresh_token'] as String? : null;
    if (refresh == null || refresh.isEmpty) {
      throw Exception('Gagal clock-in: sesi tidak diterima');
    }
    debugPrint('[Auth] Respons clock-in valid; menyiapkan sesi staf.');
    try {
      final auth = await _client.auth.setSession(refresh);
      // setSession menukar refresh token ke Auth server dan mengembalikan sesi
      // yang sudah diverifikasi. Karena itu tidak perlu memanggil getUser()
      // hingga tiga kali lagi; permintaan tambahan tersebut membuat PIN terasa
      // lambat dan tidak menambah validasi terhadap hasil setSession.
      final returnedUserId = auth.session?.user.id;
      if (returnedUserId != staffId) {
        throw Exception('Gagal clock-in: sesi staff belum siap');
      }

      // Getter sesi lokal normalnya ikut berubah sebelum setSession selesai.
      // Beberapa perangkat lambat membutuhkan satu-dua frame; tunggu singkat
      // secara lokal agar pemeriksaan pembayaran tidak membaca akun perangkat
      // lama. Tidak ada request jaringan tambahan pada loop ini.
      var activeUserId = _client.auth.currentUser?.id;
      for (var attempt = 0; activeUserId != staffId && attempt < 3; attempt++) {
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
        activeUserId = _client.auth.currentUser?.id;
      }
      if (activeUserId != staffId) {
        throw Exception('Gagal clock-in: sesi staff belum terverifikasi');
      }
      final rawProfile = data is Map ? data['profile'] : null;
      if (rawProfile is Map) {
        final cache = Hive.isBoxOpen(StaffAuthorizationLease.boxName)
            ? Hive.box<dynamic>(StaffAuthorizationLease.boxName)
            : null;
        await cache?.put(
          'auth_profile_$staffId',
          jsonEncode({
            'cached_at': DateTime.now().toUtc().toIso8601String(),
            'profile': Map<String, dynamic>.from(rawProfile),
          }),
        );
      }
      if (!await StaffAuthorizationLease.grant(staffId)) {
        throw Exception('Penyimpanan otorisasi staf belum siap');
      }
      // Verifikasi lokal hanya dibuat SETELAH server menerima PIN dan session
      // staf aktif. Refresh token disimpan terenkripsi untuk melanjutkan sync
      // otomatis ketika transaksi dibuat saat clock-in lokal/offline.
      try {
        await OfflineStaffAccessService.instance.remember(
          outletId: outletId,
          profile: profile,
          pin: pin,
        );
        await _storage.write(
          key: '$_kStaffRefreshPrefix$staffId',
          value: refresh,
        );
        await _storage.delete(key: _kOfflineActiveStaffId);
      } catch (_) {
        // Clock-in online tetap sah; hanya kemampuan clock-in offline yang
        // tidak tersedia bila penyimpanan aman perangkat bermasalah.
      }
    } catch (error) {
      debugPrint(
        '[Auth] Pergantian sesi staf gagal; memulihkan sesi perangkat.',
      );
      try {
        await restoreDeviceSession();
        debugPrint('[Auth] Sesi perangkat berhasil dipulihkan.');
      } catch (restoreError) {
        debugPrint(
          '[Auth] Sesi perangkat gagal dipulihkan: '
          '${restoreError.runtimeType}.',
        );
      }
      rethrow;
    }
    debugPrint('[Auth] Sesi staf siap; profil respons server digunakan.');
    return profile;
  }

  Future<Profile> _clockInOffline({
    required String outletId,
    required String staffId,
    required String pin,
  }) async {
    if (!OfflineBootstrapService.instance.isReady(outletId)) {
      throw Exception(
        'Data cabang belum pernah diunduh. Sambungkan internet sekali untuk '
        'menyiapkan mode offline.',
      );
    }
    final profile = await OfflineStaffAccessService.instance.authenticate(
      outletId: outletId,
      staffId: staffId,
      pin: pin,
    );
    if (profile == null) {
      throw Exception(
        'PIN offline tidak tersedia atau sudah kedaluwarsa. Sambungkan '
        'internet untuk verifikasi ulang.',
      );
    }
    if (!await StaffAuthorizationLease.grant(staffId)) {
      throw Exception('Penyimpanan otorisasi staf belum siap');
    }
    try {
      await _storage.write(key: _kOfflineActiveStaffId, value: staffId);
    } catch (_) {
      // Hive terenkripsi sudah memegang identitas transaksi. Marker ini hanya
      // membantu pemulihan otomatis dan tidak boleh menggagalkan clock-in.
    }
    return profile;
  }

  // ── Akun perangkat (gerbang per cabang) ─────────────────────────────────────
  /// Login akun perangkat cabang & simpan kredensial (untuk restore otomatis).
  /// Mengembalikan profil perangkat (untuk ambil outlet_id/nama).
  Future<Profile?> deviceLogin({
    required String email,
    required String password,
  }) async {
    final res = await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final user = res.user;
    if (user == null) throw Exception('Login perangkat gagal');
    Profile? profile;
    try {
      profile = await getProfile(user.id, allowCachedFallback: false);
    } catch (error, stackTrace) {
      // signIn sudah dapat membuat sesi walaupun query profil sesudahnya gagal.
      // Jangan biarkan akun Admin yang dimasukkan pada formulir perangkat
      // bertahan sebagai sesi staf dan terbuka tanpa clock-in pada restart.
      await _client.auth.signOut(scope: SignOutScope.local);
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (!isValidDeviceLoginProfile(profile, user.id)) {
      await clearInvalidDeviceSession();
      throw Exception(
        'Gunakan akun Perangkat Cabang yang aktif untuk login POS.',
      );
    }

    // Email berfungsi sebagai penanda commit dan sengaja ditulis terakhir.
    // Bila aplikasi mati di tengah penulisan, hasDeviceCreds akan bernilai
    // false alih-alih mencoba memulihkan pasangan email/password yang berbeda.
    await _storage.delete(key: _kDevEmail);
    await _storage.write(key: _kDevPass, value: password);
    await _storage.write(key: _kDevUserId, value: user.id);
    await _persistDeviceOutlet(profile);
    await _storage.write(
      key: _kDevVerifiedAt,
      value: DateTime.now().toUtc().toIso8601String(),
    );
    await _storage.write(key: _kDevEmail, value: email);
    await touchDeviceHeartbeat(force: true);
    return profile;
  }

  Future<void> _persistDeviceOutlet(Profile? p) async {
    if (p?.outletId != null && p!.outletId!.isNotEmpty) {
      await _storage.write(key: _kDevOutletId, value: p.outletId);
    } else {
      // Jangan mewarisi outlet dari akun perangkat yang login sebelumnya.
      await _storage.delete(key: _kDevOutletId);
    }
  }

  Future<void> touchDeviceHeartbeat({bool force = false}) {
    final active = _heartbeatInFlight;
    if (active != null) return active;
    final operation = _touchDeviceHeartbeat(force: force);
    _heartbeatInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_heartbeatInFlight, operation)) {
        _heartbeatInFlight = null;
      }
    });
  }

  Future<void> _touchDeviceHeartbeat({required bool force}) async {
    try {
      final deviceUserId = await storedDeviceUserId;
      if (!shouldSendDeviceHeartbeat(
        _client.auth.currentUser?.id,
        deviceUserId,
      )) {
        return;
      }
      final now = DateTime.now().toUtc();
      final lastAttemptRaw = await _storage.read(key: _kDevHeartbeatAttemptAt);
      final lastAttempt = lastAttemptRaw == null
          ? null
          : DateTime.tryParse(lastAttemptRaw)?.toUtc();
      if (!deviceHeartbeatIsDue(lastAttempt, now, force: force)) return;

      // Catat SEBELUM request. Akun perangkat yang dinonaktifkan menghasilkan
      // 403; tanpa throttle persisten setiap resume/restart memenuhi API logs.
      await _storage.write(
        key: _kDevHeartbeatAttemptAt,
        value: now.toIso8601String(),
      );
      await _client.rpc(
        'touch_device_heartbeat',
        params: {'p_app_version': 'mobile'},
      );
    } catch (_) {
      // Monitoring tidak boleh menghalangi login/perbaikan sesi perangkat.
    }
  }

  Future<String?> get storedDeviceUserId => _readSecureForStartup(_kDevUserId);
  Future<String?> get storedDeviceOutletId =>
      _readSecureForStartup(_kDevOutletId);

  Future<void> clearDeviceLoginCredentials() async {
    await _storage.delete(key: _kDevEmail);
    await _storage.delete(key: _kDevPass);
    await _storage.delete(key: _kDevUserId);
    await _storage.delete(key: _kDevOutletId);
    await _storage.delete(key: _kDevVerifiedAt);
    await _storage.delete(key: _kDevHeartbeatAttemptAt);
  }

  Future<void> clearInvalidDeviceSession() async {
    await _client.auth.signOut(scope: SignOutScope.local);
    await clearDeviceLoginCredentials();
  }

  Future<bool> get hasDeviceCreds async {
    final values = await Future.wait([
      _readSecureForStartup(_kDevEmail),
      _readSecureForStartup(_kDevPass),
    ]);
    return hasCompleteDeviceCredentials(values[0], values[1]);
  }

  /// Izin terbatas untuk membuka gerbang PIN saat backend sedang putus.
  /// Bukti ini hanya dibuat sesudah profil perangkat diverifikasi server dan
  /// tetap mensyaratkan cache profil ber-role perangkat yang aktif.
  Future<bool> get hasValidOfflineDeviceAuthorization async {
    try {
      final values = await Future.wait([
        _readSecureForStartup(_kDevUserId),
        _readSecureForStartup(_kDevOutletId),
        _readSecureForStartup(_kDevVerifiedAt),
      ]);
      final deviceId = values[0]?.trim();
      final outletId = values[1]?.trim();
      final verifiedAt = DateTime.tryParse(values[2] ?? '')?.toUtc();
      if (deviceId == null ||
          deviceId.isEmpty ||
          outletId == null ||
          outletId.isEmpty ||
          !deviceOfflineAuthorizationIsValid(
            verifiedAt,
            DateTime.now().toUtc(),
          )) {
        return false;
      }
      final cached = _cachedProfileWithoutLease(deviceId);
      return isValidDeviceLoginProfile(cached, deviceId) &&
          cached!.outletId == outletId;
    } catch (_) {
      return false;
    }
  }

  /// Pulihkan sesi perangkat dari kredensial tersimpan (saat app dibuka /
  /// setelah clock-out). Lempar bila kredensial tak ada / gagal.
  Future<Profile?> restoreDeviceSession() async {
    final email = await _readSecureForStartup(_kDevEmail);
    final password = await _readSecureForStartup(_kDevPass);
    if (!hasCompleteDeviceCredentials(email, password)) {
      throw Exception('Perangkat belum login cabang');
    }
    final storedEmail = email!;
    final storedPassword = password!;
    final res = await _client.auth
        .signInWithPassword(email: storedEmail, password: storedPassword)
        .timeout(_authRestoreRequestTimeout);
    final user = res.user;
    if (user == null) throw Exception('Gagal memulihkan sesi perangkat');
    await _writeSecureForStartup(_kDevUserId, user.id);
    final profile = await getProfile(user.id, allowCachedFallback: false);
    if (!isValidDeviceLoginProfile(profile, user.id)) {
      await clearInvalidDeviceSession();
      throw Exception(
        'Simpan ulang akun Perangkat Cabang yang aktif untuk login POS.',
      );
    }
    await _persistDeviceOutlet(profile);
    await _writeSecureForStartup(
      _kDevVerifiedAt,
      DateTime.now().toUtc().toIso8601String(),
    );
    await touchDeviceHeartbeat(force: true);
    return profile;
  }

  Profile? _cachedProfileWithoutLease(String userId) {
    final cache = Hive.isBoxOpen(StaffAuthorizationLease.boxName)
        ? Hive.box<dynamic>(StaffAuthorizationLease.boxName)
        : null;
    final raw = cache?.get('auth_profile_$userId') as String?;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final profile = decoded['profile'];
      return profile is Map
          ? Profile.fromJson(Map<String, dynamic>.from(profile))
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Pulihkan JWT staf setelah internet kembali agar outbox milik kasir yang
  /// clock-in secara lokal dapat tersinkron tanpa dikirim sebagai akun device.
  Future<bool> restoreStaffSessionForSync(String staffId) async {
    if (staffId.isEmpty || !ConnectivityService.instance.online.value) {
      return false;
    }
    try {
      final refresh = await _storage.read(key: '$_kStaffRefreshPrefix$staffId');
      if (refresh == null || refresh.isEmpty) return false;
      final response = await _client.auth.setSession(refresh);
      if (response.session?.user.id != staffId ||
          _client.auth.currentUser?.id != staffId) {
        return false;
      }
      final row = await _client
          .from('profiles')
          .select('role, is_active')
          .eq('id', staffId)
          .maybeSingle();
      const operationalRoles = {'owner', 'admin', 'manajer', 'kasir'};
      if (row?['is_active'] != true ||
          !operationalRoles.contains(row?['role'])) {
        await _storage.delete(key: '$_kStaffRefreshPrefix$staffId');
        return false;
      }
      await StaffAuthorizationLease.grant(staffId);
      await _storage.delete(key: _kOfflineActiveStaffId);
      return true;
    } catch (_) {
      // Token bisa dicabut/dinonaktifkan server. Outbox tetap disimpan hingga
      // staf melakukan clock-in online lagi; jangan kirim dengan akun lain.
      return false;
    }
  }

  /// Clock-out staff → kembali ke sesi perangkat (untuk layar pilih staff).
  Future<Profile?> clockOutToDevice() async {
    await _storage.delete(key: _kOfflineActiveStaffId);
    if (!ConnectivityService.instance.online.value) {
      await _client.auth.signOut(scope: SignOutScope.local);
      final deviceId = await storedDeviceUserId;
      if (deviceId == null || !await hasValidOfflineDeviceAuthorization) {
        return null;
      }
      final cached = _cachedProfileWithoutLease(deviceId);
      return isValidDeviceLoginProfile(cached, deviceId) ? cached : null;
    }
    await _client.auth.signOut();
    return restoreDeviceSession();
  }

  /// Lupakan perangkat (logout total): hapus kredensial & sesi.
  Future<void> forgetDevice() async {
    await _client.auth.signOut();
    final staffIds = OfflineStaffAccessService.instance.staffIds().toSet();
    for (final staffId in staffIds) {
      await _storage.delete(key: '$_kStaffRefreshPrefix$staffId');
    }
    await OfflineStaffAccessService.instance.clearAll();
    await clearDeviceLoginCredentials();
    await _storage.delete(key: _kOfflineActiveStaffId);
  }

  /// Atur/ganti PIN staff (tunduk hierarki di server: set_staff_pin).
  Future<void> setStaffPin({
    required String staffId,
    required String pin,
  }) async {
    await _client.rpc(
      'set_staff_pin',
      params: {'p_target': staffId, 'p_pin': pin},
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  DateTime? staffAuthorizationLeaseExpiresAt(String userId) =>
      StaffAuthorizationLease.expiresAt(userId);

  Future<void> clearStaffAuthorization(String userId) =>
      StaffAuthorizationLease.revoke(userId);

  Session? get currentSession => _client.auth.currentSession;
  User? get currentUser => _client.auth.currentUser;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;
}

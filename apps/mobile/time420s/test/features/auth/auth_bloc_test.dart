import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:time420s/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/profile.dart';
import 'package:time420s/shared/services/supabase_service.dart';

class MockSupabaseService extends Mock implements SupabaseService {}

class MockUser extends Mock implements User {
  @override
  final String id;
  MockUser(this.id);
}

class MockSession extends Mock implements Session {
  final MockUser mockUser;
  MockSession(this.mockUser);
  @override
  User get user => mockUser;
}

Profile _makeProfile({
  UserRole role = UserRole.kasir,
  String id = 'user-1',
  String? outletId = 'outlet-1',
  bool isActive = true,
}) => Profile(
  id: id,
  outletId: outletId,
  role: role,
  fullName: 'Budi Kasir',
  isActive: isActive,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late MockSupabaseService svc;

  setUp(() {
    svc = MockSupabaseService();
    // Default: perangkat tak punya outlet tersimpan (di-override bila perlu).
    when(() => svc.storedDeviceOutletId).thenAnswer((_) async => null);
    when(() => svc.storedDeviceUserId).thenAnswer((_) async => null);
    when(
      () => svc.hasValidOfflineDeviceAuthorization,
    ).thenAnswer((_) async => false);
    when(() => svc.staffAuthorizationLeaseExpiresAt(any())).thenReturn(null);
  });

  // ─── AuthCheckRequested ───────────────────────────────────────────────────
  group('AuthCheckRequested', () {
    blocTest<AuthBloc, AuthState>(
      'valid persisted device session avoids email login after restart',
      build: () {
        final session = MockSession(MockUser('device-1'));
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(() => svc.getProfile('device-1')).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.pelanggan),
        );
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [isA<AuthClockInRequired>()],
      verify: (_) => verifyNever(() => svc.hasDeviceCreds),
    );

    blocTest<AuthBloc, AuthState>(
      'legacy Admin stored as device is rejected and signed out',
      build: () {
        final session = MockSession(MockUser('device-1'));
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(() => svc.getProfile('device-1')).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.admin),
        );
        when(() => svc.clearInvalidDeviceSession()).thenAnswer((_) async {});
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [isA<AuthDeviceRequired>()],
      verify: (_) {
        verify(() => svc.clearInvalidDeviceSession()).called(1);
        verifyNever(() => svc.touchDeviceHeartbeat());
      },
    );

    blocTest<AuthBloc, AuthState>(
      'tidak ada kredensial perangkat → AuthDeviceRequired',
      build: () {
        when(() => svc.hasDeviceCreds).thenAnswer((_) async => false);
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [isA<AuthDeviceRequired>()],
    );

    blocTest<AuthBloc, AuthState>(
      'sesi staff aktif (bukan perangkat) → AuthAuthenticated',
      build: () {
        final session = MockSession(MockUser('staff-1'));
        when(() => svc.hasDeviceCreds).thenAnswer((_) async => true);
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(
          () => svc.getProfile('staff-1'),
        ).thenAnswer((_) async => _makeProfile(id: 'staff-1'));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [
        isA<AuthAuthenticated>().having((s) => s.role, 'role', 'kasir'),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'sesi perangkat aktif → AuthClockInRequired',
      build: () {
        final session = MockSession(MockUser('device-1'));
        when(() => svc.hasDeviceCreds).thenAnswer((_) async => true);
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(() => svc.getProfile('device-1')).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.pelanggan),
        );
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [
        isA<AuthClockInRequired>().having(
          (s) => s.outletId,
          'outletId',
          'outlet-1',
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'profil staf nonaktif → cache dan sesi staf dihapus',
      build: () {
        final session = MockSession(MockUser('staff-1'));
        when(() => svc.hasDeviceCreds).thenAnswer((_) async => true);
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(
          () => svc.getProfile('staff-1'),
        ).thenAnswer((_) async => _makeProfile(id: 'staff-1', isActive: false));
        when(
          () => svc.clearStaffAuthorization('staff-1'),
        ).thenAnswer((_) async {});
        when(() => svc.clockOutToDevice()).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.pelanggan),
        );
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [
        isA<AuthError>().having(
          (state) => state.message,
          'message',
          contains('dinonaktifkan'),
        ),
        isA<AuthClockInRequired>(),
      ],
      verify: (_) {
        verify(() => svc.clearStaffAuthorization('staff-1')).called(1);
        verify(() => svc.clockOutToDevice()).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'cache staf tanpa lease saat offline → sesi staf tetap dihapus',
      build: () {
        final session = MockSession(MockUser('staff-1'));
        when(() => svc.hasDeviceCreds).thenAnswer((_) async => true);
        when(() => svc.currentSession).thenReturn(session);
        when(() => svc.storedDeviceUserId).thenAnswer((_) async => 'device-1');
        when(() => svc.getProfile('staff-1')).thenThrow(Exception('offline'));
        when(
          () => svc.clearStaffAuthorization('staff-1'),
        ).thenAnswer((_) async {});
        when(() => svc.clockOutToDevice()).thenThrow(Exception('offline'));
        when(
          () => svc.storedDeviceOutletId,
        ).thenAnswer((_) async => 'outlet-1');
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [
        isA<AuthError>().having(
          (state) => state.message,
          'message',
          contains('Otorisasi offline telah berakhir'),
        ),
        isA<AuthClockInRequired>(),
      ],
      verify: (_) {
        verify(() => svc.clearStaffAuthorization('staff-1')).called(1);
        verify(() => svc.clockOutToDevice()).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'gangguan pemulihan tidak menghapus status perangkat tersimpan',
      build: () {
        when(() => svc.hasDeviceCreds).thenThrow(Exception('network down'));
        when(
          () => svc.storedDeviceOutletId,
        ).thenAnswer((_) async => 'outlet-cache');
        when(
          () => svc.hasValidOfflineDeviceAuthorization,
        ).thenAnswer((_) async => true);
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [
        isA<AuthClockInRequired>().having(
          (s) => s.outletId,
          'outletId',
          'outlet-cache',
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'marker outlet lama tanpa izin perangkat offline ditolak',
      build: () {
        when(() => svc.hasDeviceCreds).thenThrow(Exception('network down'));
        when(
          () => svc.storedDeviceOutletId,
        ).thenAnswer((_) async => 'outlet-cache');
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthCheckRequested()),
      expect: () => [isA<AuthDeviceRequired>()],
    );
  });

  // ─── AuthDeviceLoginRequested ─────────────────────────────────────────────
  group('AuthDeviceLoginRequested', () {
    blocTest<AuthBloc, AuthState>(
      'login perangkat sukses → AuthLoading, AuthClockInRequired',
      build: () {
        when(
          () => svc.deviceLogin(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.pelanggan),
        );
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthDeviceLoginRequested(
          email: 'cabang@toko.com',
          password: 'password123',
        ),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthClockInRequired>().having(
          (s) => s.outletId,
          'outletId',
          'outlet-1',
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'login perangkat gagal → AuthLoading, AuthError, AuthDeviceRequired',
      build: () {
        when(
          () => svc.deviceLogin(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(AuthException('Invalid login credentials'));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthDeviceLoginRequested(email: 'x@x.com', password: 'salah'),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthError>(),
        isA<AuthDeviceRequired>(),
      ],
    );
  });

  // ─── AuthClockInRequested ─────────────────────────────────────────────────
  group('AuthClockInRequested', () {
    blocTest<AuthBloc, AuthState>(
      'clock-in sukses → AuthLoading, AuthAuthenticated',
      build: () {
        when(
          () => svc.clockIn(
            outletId: any(named: 'outletId'),
            staffId: any(named: 'staffId'),
            pin: any(named: 'pin'),
          ),
        ).thenAnswer((_) async => _makeProfile(id: 'staff-1'));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthClockInRequested(
          outletId: 'outlet-1',
          staffId: 'staff-1',
          pin: '1234',
        ),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthAuthenticated>().having((s) => s.role, 'role', 'kasir'),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'PIN benar → profil dari respons clock-in langsung dipakai tanpa query kedua',
      build: () {
        when(
          () => svc.clockIn(
            outletId: any(named: 'outletId'),
            staffId: any(named: 'staffId'),
            pin: any(named: 'pin'),
          ),
        ).thenAnswer((_) async => _makeProfile(id: 'staff-1', outletId: null));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthClockInRequested(
          outletId: 'outlet-1',
          staffId: 'staff-1',
          pin: '1234',
        ),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthAuthenticated>()
            .having((s) => s.profile.id, 'id', 'staff-1')
            .having((s) => s.profile.outletId, 'outlet', 'outlet-1'),
      ],
      verify: (_) => verifyNever(() => svc.getProfile(any())),
    );

    blocTest<AuthBloc, AuthState>(
      'PIN salah → AuthLoading, AuthError, AuthClockInRequired',
      build: () {
        when(
          () => svc.clockIn(
            outletId: any(named: 'outletId'),
            staffId: any(named: 'staffId'),
            pin: any(named: 'pin'),
          ),
        ).thenThrow(Exception('PIN salah'));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthClockInRequested(
          outletId: 'outlet-1',
          staffId: 'staff-1',
          pin: '0000',
        ),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthError>(),
        isA<AuthClockInRequired>(),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'respons clock-in gagal → kembali ke pilihan staf tanpa query profil',
      build: () {
        when(
          () => svc.clockIn(
            outletId: any(named: 'outletId'),
            staffId: any(named: 'staffId'),
            pin: any(named: 'pin'),
          ),
        ).thenThrow(Exception('data staf tidak diterima'));
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(
        AuthClockInRequested(
          outletId: 'outlet-1',
          staffId: 'staff-1',
          pin: '1234',
        ),
      ),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthError>(),
        isA<AuthClockInRequired>().having(
          (state) => state.outletId,
          'outletId',
          'outlet-1',
        ),
      ],
      verify: (_) {
        verifyNever(() => svc.getProfile(any()));
        verifyNever(() => svc.clockOutToDevice());
      },
    );
  });

  // ─── Clock-out & device logout ────────────────────────────────────────────
  group('Logout', () {
    blocTest<AuthBloc, AuthState>(
      'AuthLogoutRequested (clock-out) → AuthLoading, AuthClockInRequired',
      build: () {
        when(() => svc.clockOutToDevice()).thenAnswer(
          (_) async => _makeProfile(id: 'device-1', role: UserRole.pelanggan),
        );
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthLogoutRequested()),
      expect: () => [isA<AuthLoading>(), isA<AuthClockInRequired>()],
      verify: (_) => verify(() => svc.clockOutToDevice()).called(1),
    );

    blocTest<AuthBloc, AuthState>(
      'AuthDeviceLogoutRequested → AuthDeviceRequired',
      build: () {
        when(() => svc.forgetDevice()).thenAnswer((_) async {});
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthDeviceLogoutRequested()),
      expect: () => [isA<AuthDeviceRequired>()],
      verify: (_) => verify(() => svc.forgetDevice()).called(1),
    );

    final logoutCalls = <String>[];
    blocTest<AuthBloc, AuthState>(
      'pekerjaan latar selesai sebelum sesi staff ditukar saat clock-out',
      seed: () => AuthAuthenticated(profile: _makeProfile(id: 'staff-1')),
      build: () {
        when(
          () => svc.clearStaffAuthorization('staff-1'),
        ).thenAnswer((_) async => logoutCalls.add('clear-authorization'));
        when(() => svc.clockOutToDevice()).thenAnswer((_) async {
          logoutCalls.add('clock-out');
          return _makeProfile(id: 'device-1', role: UserRole.pelanggan);
        });
        return AuthBloc(
          supabaseService: svc,
          stopNotifications: () async =>
              logoutCalls.add('stop-background-work'),
        );
      },
      act: (bloc) => bloc.add(AuthLogoutRequested()),
      expect: () => [isA<AuthLoading>(), isA<AuthClockInRequired>()],
      verify: (bloc) {
        // Callback stop mencakup notifikasi, retry printer, dan SyncService di
        // root App. Yang dikunci di sini adalah barrier sebelum sign-out.
        verify(() => svc.clockOutToDevice()).called(1);
        expect(logoutCalls, [
          'stop-background-work',
          'clear-authorization',
          'clock-out',
        ]);
      },
    );
  });

  group('Authorization lease', () {
    blocTest<AuthBloc, AuthState>(
      'lease habis dan server tidak terjangkau → sesi staf ditutup',
      seed: () => AuthAuthenticated(profile: _makeProfile(id: 'staff-1')),
      build: () {
        when(() => svc.getProfile('staff-1')).thenThrow(Exception('offline'));
        when(
          () => svc.clearStaffAuthorization('staff-1'),
        ).thenAnswer((_) async {});
        when(() => svc.clockOutToDevice()).thenThrow(Exception('offline'));
        when(
          () => svc.storedDeviceOutletId,
        ).thenAnswer((_) async => 'outlet-1');
        return AuthBloc(supabaseService: svc);
      },
      act: (bloc) => bloc.add(AuthAuthorizationLeaseExpired()),
      expect: () => [
        isA<AuthError>().having(
          (state) => state.message,
          'message',
          contains('Otorisasi offline telah berakhir'),
        ),
        isA<AuthClockInRequired>().having(
          (state) => state.outletId,
          'outletId',
          'outlet-1',
        ),
      ],
      verify: (_) {
        verify(() => svc.clearStaffAuthorization('staff-1')).called(1);
        verify(() => svc.clockOutToDevice()).called(1);
      },
    );
  });
}

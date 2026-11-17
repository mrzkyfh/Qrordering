import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../../shared/models/profile.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/supabase_service.dart';

// Events
abstract class AuthEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthCheckRequested extends AuthEvent {}

/// Login akun perangkat cabang (gerbang). Setelah ini muncul layar clock-in.
class AuthDeviceLoginRequested extends AuthEvent {
  final String email;
  final String password;
  AuthDeviceLoginRequested({required this.email, required this.password});
  @override
  List<Object?> get props => [email, password];
}

/// Clock-in via PIN: tukar PIN → session staff (edge function clock-in).
class AuthClockInRequested extends AuthEvent {
  final String outletId;
  final String staffId;
  final String pin;
  AuthClockInRequested({
    required this.outletId,
    required this.staffId,
    required this.pin,
  });
  @override
  List<Object?> get props => [outletId, staffId, pin];
}

/// Clock-out staff → kembali ke layar pilih staff (sesi perangkat).
class AuthLogoutRequested extends AuthEvent {}

/// Lupakan perangkat (logout total akun cabang) → layar login perangkat.
class AuthDeviceLogoutRequested extends AuthEvent {}

/// Dipicu saat lease otorisasi staf habis. Server diberi kesempatan untuk
/// memperbaruinya; bila tidak terjangkau, sesi staf ditutup secara fail-closed.
class AuthAuthorizationLeaseExpired extends AuthEvent {}

/// Owner memilih outlet aktif untuk masuk mode operasional Kasir.
/// Meng-override outletId pada profil agar shell & bloc memuat data outlet itu.
class AuthActiveOutletChanged extends AuthEvent {
  final String outletId;
  final String? outletName;
  AuthActiveOutletChanged(this.outletId, {this.outletName});
  @override
  List<Object?> get props => [outletId, outletName];
}

// States
abstract class AuthState extends Equatable {
  @override
  List<Object?> get props => [];
}

class AuthLoading extends AuthState {}

/// Perangkat belum login cabang → tampilkan layar login email/password.
class AuthDeviceRequired extends AuthState {}

/// Perangkat sudah login cabang → tampilkan layar pilih staff + PIN.
class AuthClockInRequired extends AuthState {
  final String outletId;
  final String? outletName;
  AuthClockInRequired(this.outletId, {this.outletName});
  @override
  List<Object?> get props => [outletId, outletName];
}

class AuthAuthenticated extends AuthState {
  final Profile profile;
  String get role => profile.role.value;

  AuthAuthenticated({required this.profile});

  @override
  List<Object?> get props => [profile];
}

class AuthError extends AuthState {
  final String message;
  AuthError(this.message);
  @override
  List<Object?> get props => [message];
}

// BLoC
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final SupabaseService supabaseService;
  final Future<void> Function() _stopNotifications;

  String? _deviceOutletId;
  String? _deviceOutletName;
  Timer? _authorizationLeaseTimer;

  AuthBloc({
    required this.supabaseService,
    Future<void> Function()? stopNotifications,
  }) : _stopNotifications = stopNotifications ?? _noOpStopNotifications,
       super(AuthLoading()) {
    on<AuthCheckRequested>(_onCheckRequested);
    on<AuthDeviceLoginRequested>(_onDeviceLoginRequested);
    on<AuthClockInRequested>(_onClockInRequested);
    on<AuthLogoutRequested>(_onLogoutRequested);
    on<AuthDeviceLogoutRequested>(_onDeviceLogoutRequested);
    on<AuthAuthorizationLeaseExpired>(_onAuthorizationLeaseExpired);
    on<AuthActiveOutletChanged>(_onActiveOutletChanged);
  }

  void _onActiveOutletChanged(
    AuthActiveOutletChanged event,
    Emitter<AuthState> emit,
  ) {
    final s = state;
    if (s is! AuthAuthenticated) return;
    _emitAuthenticated(
      s.profile.copyWith(
        outletId: event.outletId,
        outletName: event.outletName,
      ),
      emit,
    );
  }

  Future<void> _onCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    if (state is! AuthLoading) emit(AuthLoading());
    try {
      final session = supabaseService.currentSession;
      final deviceUserId = await supabaseService.storedDeviceUserId;

      // Known staff session: keep the existing authorization-lease checks and
      // fail-closed behavior when the server cannot revalidate it.
      if (session != null &&
          deviceUserId != null &&
          session.user.id != deviceUserId) {
        _deviceOutletId ??= await supabaseService.storedDeviceOutletId;
        await _loadProfile(session.user.id, emit);
        return;
      }

      // Supabase restores its refresh token independently of the encrypted
      // device credentials. Prefer that valid session after process restart,
      // including during storage migrations, so closing the app never forces
      // the user back to email/password.
      if (session != null) {
        final profile = await supabaseService.getProfile(session.user.id);
        if (session.user.id == deviceUserId) {
          if (isValidDeviceLoginProfile(profile, session.user.id)) {
            _setDeviceOutlet(profile);
            emit(
              AuthClockInRequired(
                _deviceOutletId ?? '',
                outletName: _deviceOutletName,
              ),
            );
            return;
          }

          // Kredensial perangkat dari versi lama mungkin pernah menyimpan
          // akun Admin/staf. Jangan migrasikan akun tersebut menjadi sesi POS
          // tanpa PIN: hapus sesi dan minta akun Perangkat yang benar.
          await supabaseService.clearInvalidDeviceSession();
          _deviceOutletId = null;
          _deviceOutletName = null;
          emit(AuthDeviceRequired());
          return;
        }

        if (profile != null) {
          final operational = switch (profile.role) {
            UserRole.owner ||
            UserRole.admin ||
            UserRole.manajer ||
            UserRole.kasir => true,
            _ => false,
          };
          if (session.user.id != deviceUserId && operational) {
            if (!profile.isActive) {
              await _endStaffSession(
                profile.id,
                emit,
                message: 'Akun staf dinonaktifkan. Hubungi administrator.',
              );
              return;
            }
            _deviceOutletId ??= await supabaseService.storedDeviceOutletId;
            final effective =
                (profile.outletId == null || profile.outletId!.isEmpty) &&
                    (_deviceOutletId?.isNotEmpty ?? false)
                ? profile.copyWith(outletId: _deviceOutletId)
                : profile;
            _emitAuthenticated(effective, emit);
            return;
          }
          _setDeviceOutlet(profile);
          emit(
            AuthClockInRequired(
              _deviceOutletId ?? '',
              outletName: _deviceOutletName,
            ),
          );
          return;
        }
      }

      if (!await supabaseService.hasDeviceCreds) {
        emit(AuthDeviceRequired());
        return;
      }

      // Pastikan sesi perangkat aktif, lalu tampilkan layar pilih staff.
      Profile? device;
      if (session == null) {
        device = await supabaseService.restoreDeviceSession();
      } else {
        device = await supabaseService.getProfile(session.user.id);
      }
      _setDeviceOutlet(device);
      emit(
        AuthClockInRequired(
          _deviceOutletId ?? '',
          outletName: _deviceOutletName,
        ),
      );
    } catch (error) {
      debugPrint('[Auth] Pemulihan sesi belum tersedia: $error');
      // Gangguan jaringan tidak berarti kredensial perangkat hilang. Bila
      // outlet dan bukti verifikasi perangkat masih sah, pertahankan alur
      // operasional agar data offline/cached tetap dapat dibuka. Marker outlet
      // saja tidak cukup karena versi lama pernah menyimpan akun Admin sebagai
      // perangkat.
      try {
        final storedOutlet = await supabaseService.storedDeviceOutletId;
        if (storedOutlet != null &&
            storedOutlet.isNotEmpty &&
            await supabaseService.hasValidOfflineDeviceAuthorization) {
          _deviceOutletId = storedOutlet;
          emit(AuthClockInRequired(storedOutlet));
          return;
        }
      } catch (_) {
        // Secure storage benar-benar tidak dapat dibaca; login ulang aman.
      }
      emit(AuthDeviceRequired());
    }
  }

  Future<void> _onDeviceLoginRequested(
    AuthDeviceLoginRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final device = await supabaseService.deviceLogin(
        email: event.email,
        password: event.password,
      );
      _setDeviceOutlet(device);
      emit(
        AuthClockInRequired(
          _deviceOutletId ?? '',
          outletName: _deviceOutletName,
        ),
      );
    } catch (e) {
      emit(AuthError(e.toString()));
      emit(AuthDeviceRequired());
    }
  }

  Future<void> _onClockInRequested(
    AuthClockInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final profile = await supabaseService.clockIn(
        outletId: event.outletId,
        staffId: event.staffId,
        pin: event.pin,
      );
      // Profil sudah ikut dalam respons server yang memverifikasi PIN. Tidak
      // perlu query kedua yang sebelumnya dapat terlambat setelah sesi berubah.
      final effective = profile.copyWith(
        outletId: (profile.outletId == null || profile.outletId!.isEmpty)
            ? event.outletId
            : profile.outletId,
        outletName: profile.outletName ?? _deviceOutletName,
      );
      if (!profile.isActive) {
        await _endStaffSession(
          profile.id,
          emit,
          message: 'Akun staf dinonaktifkan. Hubungi administrator.',
          fallbackOutletId: event.outletId,
        );
        return;
      }
      _emitAuthenticated(effective, emit);
    } catch (e) {
      // Tidak pernah mencatat PIN atau token. Tahap dan jenis error ini cukup
      // untuk diagnosis perangkat bila masalah berulang.
      debugPrint('[Auth] Clock-in gagal: ${e.runtimeType}: $e');
      emit(AuthError(e.toString()));
      // PIN gagal → sesi perangkat tetap aktif, kembali ke layar pilih staff.
      emit(
        AuthClockInRequired(
          _deviceOutletId ?? event.outletId,
          outletName: _deviceOutletName,
        ),
      );
    }
  }

  Future<void> _onLogoutRequested(
    AuthLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    final staffId = state is AuthAuthenticated
        ? (state as AuthAuthenticated).profile.id
        : null;
    emit(AuthLoading());
    await _stopNotifications();
    try {
      if (staffId != null) {
        try {
          await supabaseService.clearStaffAuthorization(staffId);
        } catch (_) {
          // Sesi tetap wajib dihapus meski penyimpanan cache bermasalah.
        }
      }
      _authorizationLeaseTimer?.cancel();
      final device = await supabaseService.clockOutToDevice();
      _setDeviceOutlet(device);
      _deviceOutletId ??= await supabaseService.storedDeviceOutletId;
      emit(
        AuthClockInRequired(
          _deviceOutletId ?? '',
          outletName: _deviceOutletName,
        ),
      );
    } catch (_) {
      // Bila gagal pulihkan perangkat, minta login cabang lagi.
      emit(AuthDeviceRequired());
    }
  }

  Future<void> _onDeviceLogoutRequested(
    AuthDeviceLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    final staffId = state is AuthAuthenticated
        ? (state as AuthAuthenticated).profile.id
        : null;
    await _stopNotifications();
    if (staffId != null) {
      try {
        await supabaseService.clearStaffAuthorization(staffId);
      } catch (_) {
        // forgetDevice di bawah tetap harus dijalankan.
      }
    }
    _authorizationLeaseTimer?.cancel();
    await supabaseService.forgetDevice();
    _deviceOutletId = null;
    _deviceOutletName = null;
    emit(AuthDeviceRequired());
  }

  void _setDeviceOutlet(Profile? device) {
    _deviceOutletId = device?.outletId;
    _deviceOutletName = device?.outletName;
  }

  Future<void> _loadProfile(String userId, Emitter<AuthState> emit) async {
    Profile? profile;
    Object? lastError;
    try {
      profile = await supabaseService.getProfile(userId);
    } catch (e) {
      lastError = e;
    }

    if (profile != null) {
      if (!profile.isActive) {
        await _endStaffSession(
          profile.id,
          emit,
          message: 'Akun staf dinonaktifkan. Hubungi administrator.',
        );
        return;
      }
      // Staf tanpa outlet sendiri (mis. owner multi-outlet) → pakai outlet
      // perangkat tempat ia clock-in, agar POS bisa memuat menu outlet itu.
      final effective =
          (profile.outletId == null || profile.outletId!.isEmpty) &&
              (_deviceOutletId != null && _deviceOutletId!.isNotEmpty)
          ? profile.copyWith(outletId: _deviceOutletId)
          : profile;
      _emitAuthenticated(effective, emit);
      return;
    }

    await _endStaffSession(
      userId,
      emit,
      message: lastError == null
          ? 'Profil staf tidak ditemukan. Silakan masuk kembali.'
          : 'Otorisasi offline telah berakhir. Sambungkan perangkat ke server '
                'untuk masuk kembali.',
    );
  }

  void _emitAuthenticated(Profile profile, Emitter<AuthState> emit) {
    emit(AuthAuthenticated(profile: profile));
    _authorizationLeaseTimer?.cancel();
    final expiresAt = supabaseService.staffAuthorizationLeaseExpiresAt(
      profile.id,
    );
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    _authorizationLeaseTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => add(AuthAuthorizationLeaseExpired()),
    );
  }

  Future<void> _onAuthorizationLeaseExpired(
    AuthAuthorizationLeaseExpired event,
    Emitter<AuthState> emit,
  ) async {
    final current = state;
    if (current is! AuthAuthenticated) return;

    try {
      // getProfile hanya akan memakai cache bila lease masih aktif. Karena event
      // ini muncul saat lease habis, keberhasilan di sini berarti server benar-
      // benar mengonfirmasi ulang bahwa staf masih aktif.
      final refreshed = await supabaseService.getProfile(current.profile.id);
      if (refreshed != null && refreshed.isActive) {
        final effective = refreshed.copyWith(
          outletId: (refreshed.outletId == null || refreshed.outletId!.isEmpty)
              ? current.profile.outletId
              : refreshed.outletId,
          outletName: refreshed.outletName ?? current.profile.outletName,
        );
        _emitAuthenticated(effective, emit);
        return;
      }
      await _endStaffSession(
        current.profile.id,
        emit,
        message: 'Akun staf dinonaktifkan. Hubungi administrator.',
      );
    } catch (_) {
      await _endStaffSession(
        current.profile.id,
        emit,
        message:
            'Otorisasi offline telah berakhir. Sambungkan perangkat ke server '
            'untuk masuk kembali.',
      );
    }
  }

  Future<void> _endStaffSession(
    String staffId,
    Emitter<AuthState> emit, {
    required String message,
    String? fallbackOutletId,
  }) async {
    _authorizationLeaseTimer?.cancel();
    await _stopNotifications();
    try {
      await supabaseService.clearStaffAuthorization(staffId);
    } catch (_) {
      // Penghapusan sesi di bawah lebih penting daripada cleanup cache.
    }
    emit(AuthError(message));
    try {
      final device = await supabaseService.clockOutToDevice();
      _setDeviceOutlet(device);
      emit(
        AuthClockInRequired(
          _deviceOutletId ?? fallbackOutletId ?? '',
          outletName: _deviceOutletName,
        ),
      );
      return;
    } catch (_) {
      // clockOutToDevice sudah menghapus sesi staf sebelum mencoba login akun
      // perangkat. Bila perangkat offline, outlet tersimpan masih cukup untuk
      // kembali ke layar clock-in (clock-in berikutnya tetap butuh server).
    }
    final storedOutlet =
        fallbackOutletId ?? await supabaseService.storedDeviceOutletId;
    if (storedOutlet != null && storedOutlet.isNotEmpty) {
      _deviceOutletId = storedOutlet;
      emit(AuthClockInRequired(storedOutlet));
    } else {
      emit(AuthDeviceRequired());
    }
  }

  @override
  Future<void> close() {
    _authorizationLeaseTimer?.cancel();
    return super.close();
  }
}

Future<void> _noOpStopNotifications() async {}

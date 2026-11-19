import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:toastification/toastification.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'shared/services/supabase_service.dart';
import 'shared/services/notification_service.dart';
import 'shared/services/keep_alive_service.dart';
import 'shared/services/printer_service.dart';
import 'shared/services/encrypted_hive_service.dart';
import 'shared/widgets/new_order_banner_host.dart';
import 'core/widgets/version_gate.dart';
import 'core/startup/startup_support.dart';
import 'core/config/app_config.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  late bool _showStorageRecoveryNotice;

  @override
  void initState() {
    super.initState();
    _showStorageRecoveryNotice = EncryptedHiveService.recoveryEvents.isNotEmpty;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Prompt sistem/keyboard dapat mengubah mode window. Pulihkan edge-to-edge
    // saat kembali agar perilakunya konsisten pada semua versi Android.
    if (state == AppLifecycleState.resumed) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      // Jika sesi yang aktif masih akun perangkat, catat aktivitas terakhir.
      // Saat sesi sudah ditukar menjadi staf, RPC akan menolak secara aman.
      unawaited(SupabaseService().touchDeviceHeartbeat());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => AuthBloc(
        supabaseService: SupabaseService(),
        // Callback ini harus selesai sebelum AuthBloc menukar/menghapus
        // JWT. Selain realtime, timer retry printer dan drain outbox juga
        // dapat memanggil RPC tiket dapur.
        stopNotifications: _pauseStaffBackgroundWork,
      )..add(AuthCheckRequested()),
      child: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) async {
          if (state is AuthAuthenticated) {
            StartupDiagnostics.phase('ready');
            PrinterService().resumePendingPrintRetries();
            final outletId = state.profile.outletId;
            navigateBeforeCleanup(
              navigate: () => AppRouter.router.go('/orders'),
              cleanup: () => _startAuthenticatedBackgroundWork(state, outletId),
            );
          } else if (state is AuthClockInRequired) {
            StartupDiagnostics.phase('ready');
            navigateBeforeCleanup(
              navigate: () => AppRouter.router.go('/clock-in'),
              cleanup: _cleanupAfterAuthChange,
            );
          } else if (state is AuthDeviceRequired) {
            StartupDiagnostics.phase('ready');
            navigateBeforeCleanup(
              navigate: () => AppRouter.router.go('/login'),
              cleanup: _cleanupAfterAuthChange,
            );
          }
        },
        child: MaterialApp.router(
          title: 'QR Ordering',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          routerConfig: AppRouter.router,
          builder: (context, child) {
            // Batasi skala agar kartu dapur tetap mudah dipindai di layar kecil.
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: mq.textScaler.clamp(
                  minScaleFactor: 0.85,
                  maxScaleFactor: 1.2,
                ),
              ),
              child: SafeArea(
                // Scaffold tetap menggambar background sampai ke tepi layar,
                // tetapi seluruh konten interaktif aman dari status/navigation
                // bar, display cutout, dan gesture area.
                child: Column(
                  children: [
                    if (_showStorageRecoveryNotice)
                      Material(
                        color: const Color(0xFFFFF7ED),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Color(0xFFC2410C),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Penyimpanan lokal sempat bermasalah dan '
                                  'sudah dipulihkan. Berkas lama diamankan; '
                                  'jangan uninstall, laporkan ke admin.',
                                  style: TextStyle(
                                    color: Color(0xFF9A3412),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Tutup pemberitahuan',
                                onPressed: () => setState(
                                  () => _showStorageRecoveryNotice = false,
                                ),
                                icon: const Icon(Icons.close, size: 18),
                                color: const Color(0xFF9A3412),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: ToastificationWrapper(
                        child: NewOrderBannerHost(
                          child: AuthWatchdog(
                            child: VersionGate(
                              child: child ?? const SizedBox(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Future<void> _pauseStaffBackgroundWork() async {
  // Ketiganya disetel ke mode berhenti sebelum await pertama selesai, lalu
  // ditunggu bersama agar tidak ada RPC yang lolos setelah sign-out.
  await Future.wait([
    NotificationService().stop(),
    PrinterService().pausePendingPrintRetries(),
  ]);
}

const _backgroundCleanupTimeout = Duration(seconds: 8);

Future<void> _cleanupAfterAuthChange() async {
  try {
    await Future.wait([
      _pauseStaffBackgroundWork(),
      KeepAliveService.instance.stop(),
    ]).timeout(_backgroundCleanupTimeout);
  } catch (error, stack) {
    debugPrint('AUTH background cleanup warning: $error\n$stack');
  }
}

Future<void> _startAuthenticatedBackgroundWork(
  AuthAuthenticated state,
  String? outletId,
) async {
  if (outletId == null || outletId.isEmpty) return;
  final operationalRoles = {'owner', 'kasir', 'admin', 'manajer'};
  if (!operationalRoles.contains(state.role)) return;
  try {
    final notif = NotificationService();
    try {
      await notif.init().timeout(const Duration(seconds: 10));
    } catch (error) {
      // Kegagalan inisialisasi notifikasi tidak boleh mematikan listener order
      // yang bertanggung jawab atas cetak otomatis tiket dapur.
      debugPrint('AUTH notification init warning: $error');
    }
    await notif.startWatching(outletId).timeout(const Duration(seconds: 12));
    await KeepAliveService.instance.start().timeout(const Duration(seconds: 8));
  } catch (error, stack) {
    debugPrint('AUTH background startup warning: $error\n$stack');
  }
}

void navigateBeforeCleanup({
  required VoidCallback navigate,
  required Future<void> Function() cleanup,
}) {
  navigate();
  unawaited(cleanup());
}

class AuthWatchdog extends StatefulWidget {
  const AuthWatchdog({
    super.key,
    required this.child,
    this.deadline = const Duration(seconds: 18),
  });

  final Widget child;
  final Duration deadline;

  @override
  State<AuthWatchdog> createState() => _AuthWatchdogState();
}

class _AuthWatchdogState extends State<AuthWatchdog> {
  Timer? _timer;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(widget.deadline, () {
      if (!mounted || context.read<AuthBloc>().state is! AuthLoading) return;
      final error = StartupTimeoutException(
        'AUTH_RESTORE_TIMEOUT',
        widget.deadline,
      );
      unawaited(
        StartupDiagnostics.recordFailure(
          error,
          StackTrace.current,
          appBuild: AppConfig.appBuild,
          phaseOverride: 'auth_restore',
        ),
      );
      setState(() => _timedOut = true);
    });
  }

  void _retry() {
    setState(() => _timedOut = false);
    _arm();
    context.read<AuthBloc>().add(AuthCheckRequested());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: (_, state) {
        if (state is AuthAuthenticated ||
            state is AuthClockInRequired ||
            state is AuthDeviceRequired) {
          _timer?.cancel();
          if (_timedOut) setState(() => _timedOut = false);
        } else if (state is AuthLoading && !_timedOut) {
          _arm();
        }
      },
      child: _timedOut ? _AuthRecoveryView(onRetry: _retry) : widget.child,
    );
  }
}

class _AuthRecoveryView extends StatelessWidget {
  const _AuthRecoveryView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_clock_rounded, size: 52),
                const SizedBox(height: 16),
                const Text(
                  'Tidak dapat membuka aplikasi',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Kami mengalami kendala saat memulihkan sesi. Silakan coba '
                  'kembali. Data transaksi lokal tidak dihapus.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Coba Lagi'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

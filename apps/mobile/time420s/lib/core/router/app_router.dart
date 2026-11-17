import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/pages/splash_page.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/pages/clock_in_page.dart';
import '../../features/auth/presentation/pages/profile_page.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/pos/presentation/bloc/shift_bloc.dart';
import '../../features/pos/data/datasources/shift_datasource.dart';
import '../../features/pos/presentation/pages/kasir_shell.dart';
import '../../features/pos/presentation/pages/pos_page.dart';
import '../../features/pos/presentation/pages/payment_page.dart';
import '../../features/pos/presentation/pages/kasir_report_page.dart';
import '../../features/pos/presentation/pages/table_select_page.dart';
import '../../features/pos/presentation/pages/shift_page.dart';
import '../../features/pos/presentation/pages/attendance_page.dart';
import '../../features/pos/presentation/pages/device_settings_page.dart';
import '../../features/settings/presentation/pages/settings_hub_page.dart';
import '../../features/pos/presentation/bloc/pos_bloc.dart';
import '../../features/orders/presentation/pages/order_list_page.dart';
import '../../features/orders/presentation/pages/penjualan_page.dart';
import '../../features/customer_menu/presentation/pages/qr_scanner_page.dart';
import '../../features/customer_menu/presentation/pages/customer_menu_page.dart';

class AppRouter {
  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _kasirNavKey = GlobalKey<NavigatorState>();

  static final router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashPage()),
      GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
      GoRoute(
        path: '/clock-in',
        builder: (context, state) => const ClockInPage(),
      ),

      // Full-screen routes — PosBloc tersedia dari app-level MultiBlocProvider
      GoRoute(
        path: '/kasir/payment',
        builder: (context, state) => const PaymentPage(),
      ),
      GoRoute(
        path: '/kasir/tables',
        builder: (context, state) => const TableSelectPage(),
      ),
      GoRoute(
        path: '/kasir/printer',
        builder: (context, state) => const DeviceSettingsPage(),
      ),

      // ─── Kasir shell ─────────────────────────────────────────────────────
      ShellRoute(
        navigatorKey: _kasirNavKey,
        builder: (context, state, child) {
          // Trigger menu load jika belum ada data ATAU outlet berganti
          // (PosBloc singleton app-level → harus reload saat ganti cabang).
          final posBloc = context.read<PosBloc>();
          final auth = context.read<AuthBloc>().state;
          final outletId = auth is AuthAuthenticated
              ? auth.profile.outletId ?? ''
              : '';
          final kasirId = auth is AuthAuthenticated ? auth.profile.id : '';
          final needLoad =
              posBloc.state.menuItems.isEmpty ||
              posBloc.state.loadedOutletId != outletId;
          if (auth is AuthAuthenticated &&
              needLoad &&
              !posBloc.state.menuLoading) {
            posBloc.add(PosMenuLoadRequested(outletId));
          }
          // ShiftBloc hanya memuat status shift untuk menu/halaman Buka Kasir.
          // Login tetap masuk ke aplikasi tanpa membuat atau memaksa shift.
          return BlocProvider<ShiftBloc>(
            key: ValueKey('shift:$outletId:$kasirId'),
            create: (_) =>
                ShiftBloc(datasource: ShiftDatasource())
                  ..add(ShiftLoadRequested(outletId, kasirId)),
            child: KasirShell(child: KasirSessionHost(child: child)),
          );
        },
        routes: [
          GoRoute(path: '/kasir', builder: (context, state) => const PosPage()),
          GoRoute(
            path: '/kasir/orders',
            builder: (context, state) => const OrderListPage(),
          ),
          GoRoute(
            path: '/kasir/penjualan',
            builder: (context, state) => const PenjualanPage(),
          ),
          GoRoute(
            path: '/kasir/laporan',
            builder: (context, state) =>
                KasirReportPage(initialCategory: (state.extra as int?) ?? 0),
          ),
          // Laporan role kasir hanya memuat riwayat buka/tutup shift.
          // Rekap Kas Masuk/Keluar dibatasi untuk owner/admin/manajer.
          GoRoute(
            path: '/kasir/laporan-kas',
            builder: (context, state) =>
                const KasirReportPage(allowedCategories: [3]),
          ),
          GoRoute(
            path: '/kasir/shift',
            builder: (context, state) => const ShiftPage(),
          ),
          GoRoute(
            path: '/kasir/absensi',
            builder: (context, state) => const AttendancePage(),
          ),
          GoRoute(
            path: '/kasir/profile',
            builder: (context, state) => const ProfilePage(),
          ),
          GoRoute(
            path: '/kasir/pengaturan',
            builder: (context, state) => const SettingsHubPage(),
          ),
        ],
      ),

      // ─── Pelanggan ───────────────────────────────────────────────────────
      GoRoute(
        path: '/scan',
        builder: (context, state) => const QrScannerPage(),
      ),
      GoRoute(
        path: '/menu/:tableToken',
        builder: (context, state) =>
            CustomerMenuPage(tableToken: state.pathParameters['tableToken']!),
      ),
    ],
  );
}

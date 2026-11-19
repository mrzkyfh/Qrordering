import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/pages/clock_in_page.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/pages/profile_page.dart';
import '../../features/auth/presentation/pages/splash_page.dart';
import '../../features/orders/presentation/pages/kitchen_orders_page.dart';
import '../../features/orders/presentation/pages/operations_shell.dart';

class AppRouter {
  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _operationsNavigatorKey = GlobalKey<NavigatorState>();

  static final router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/clock-in', builder: (_, _) => const ClockInPage()),
      ShellRoute(
        navigatorKey: _operationsNavigatorKey,
        builder: (_, _, child) => OperationsShell(child: child),
        routes: [
          GoRoute(
            path: '/orders',
            builder: (_, _) => const KitchenOrdersPage(),
          ),
          GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
        ],
      ),
    ],
  );
}

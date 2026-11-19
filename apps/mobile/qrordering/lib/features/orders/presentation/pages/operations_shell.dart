import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';

class OperationsShell extends StatelessWidget {
  const OperationsShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final profileActive = GoRouterState.of(context).uri.path == '/profile';
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: profileActive ? 1 : 0,
        onDestinationSelected: (index) =>
            context.go(index == 0 ? '/orders' : '/profile'),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.soup_kitchen_outlined),
            selectedIcon: Icon(Icons.soup_kitchen),
            label: 'Pesanan & Dapur',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
      floatingActionButton: profileActive
          ? FloatingActionButton.extended(
              onPressed: () =>
                  context.read<AuthBloc>().add(AuthLogoutRequested()),
              icon: const Icon(Icons.logout),
              label: const Text('Keluar'),
            )
          : null,
    );
  }
}

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Error state seragam: ikon + pesan + tombol "Coba lagi".
/// Dipakai lintas-layar (POS, Daftar Order, dll) agar konsisten.
class AppErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final String retryLabel;

  const AppErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryLabel = 'Coba lagi',
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    );
  }
}

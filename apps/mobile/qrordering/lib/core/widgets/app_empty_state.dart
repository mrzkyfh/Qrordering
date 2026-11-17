import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import '../theme/app_colors.dart';

/// Empty-state modern: animasi Lottie (pulse) + ikon + judul + subjudul.
/// Dipakai konsisten di seluruh layar (cart, order, laporan, dst).
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Lottie.asset('assets/lottie/empty.json',
                    width: 120, height: 120, repeat: true),
                Icon(icon, size: 44, color: AppColors.primary),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: AppColors.textSecondary)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textDisabled, fontSize: 13)),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

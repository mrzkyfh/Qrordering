import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_colors.dart';

/// Kotak skeleton ber-shimmer (placeholder loading modern).
class Skeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Bungkus konten dengan efek shimmer.
class AppShimmer extends StatelessWidget {
  final Widget child;
  const AppShimmer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.surfaceVariant,
      highlightColor: const Color(0xFFFAFAFA),
      child: child,
    );
  }
}

/// Skeleton kartu menu (mirip [MenuItemCard]) untuk grid loading POS.
class MenuCardSkeleton extends StatelessWidget {
  const MenuCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: Skeleton(height: double.infinity, radius: 16)),
          Padding(
            padding: EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(width: 110, height: 12),
                SizedBox(height: 8),
                Skeleton(width: 70, height: 10),
                SizedBox(height: 10),
                Skeleton(width: 60, height: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid skeleton untuk area menu POS saat loading.
class MenuGridSkeleton extends StatelessWidget {
  final int count;
  const MenuGridSkeleton({super.key, this.count = 9});

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          childAspectRatio: 0.72,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: count,
        itemBuilder: (_, _) => const MenuCardSkeleton(),
      ),
    );
  }
}

/// Skeleton baris daftar (kartu order / list) — beberapa baris.
class ListSkeleton extends StatelessWidget {
  final int rows;
  final double itemHeight;
  const ListSkeleton({super.key, this.rows = 5, this.itemHeight = 72});

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rows,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, _) => Skeleton(height: itemHeight, radius: 16),
      ),
    );
  }
}

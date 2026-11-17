import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';

/// Gambar aset backend dengan failover otomatis antara host Supabase dan
/// gateway jaringan. Error baru ditampilkan setelah seluruh jalur gagal.
class BackendNetworkImage extends StatelessWidget {
  const BackendNetworkImage({
    super.key,
    required this.imageUrl,
    required this.placeholderBuilder,
    required this.errorBuilder,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
  });

  final String imageUrl;
  final WidgetBuilder placeholderBuilder;
  final WidgetBuilder errorBuilder;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;

  @override
  Widget build(BuildContext context) {
    final candidates = AppConfig.resolveBackendAssetUrls(imageUrl);
    if (candidates.isEmpty) return errorBuilder(context);
    return _buildCandidate(context, candidates, 0);
  }

  Widget _buildCandidate(
    BuildContext context,
    List<String> candidates,
    int index,
  ) {
    return CachedNetworkImage(
      imageUrl: candidates[index],
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: (context, _) => placeholderBuilder(context),
      errorWidget: (context, _, _) {
        final next = index + 1;
        if (next < candidates.length) {
          return _buildCandidate(context, candidates, next);
        }
        return errorBuilder(context);
      },
    );
  }
}

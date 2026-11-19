import 'package:flutter/material.dart';
import '../../../../shared/models/menu_item.dart';
import '../../../../shared/widgets/backend_network_image.dart';
import '../../../../core/utils/currency_formatter.dart';

const _kRed = Color(0xFF0F766E);

Color _categoryBg(String? category) {
  if (category == null) return const Color(0xFFF5F5F5);
  final c = category.toLowerCase();
  if (c.contains('dessert')) return const Color(0xFFE8F5E9);
  if (c.contains('snack')) return const Color(0xFFFFF3E0);
  if (c.contains('burger')) return const Color(0xFFFCE4EC);
  if (c.contains('sup') || c.contains('soto')) return const Color(0xFFE3F2FD);
  if (c.contains('ayam')) return const Color(0xFFF1F8E9);
  if (c.contains('minum')) return const Color(0xFFE8EAF6);
  return const Color(0xFFF5F5F5);
}

class MenuItemCard extends StatelessWidget {
  // Dense tablet cards keep price and add action visible in three columns.
  final bool compact;
  final MenuItem item;
  final int quantity;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const MenuItemCard({
    super.key,
    this.compact = false,
    required this.item,
    required this.quantity,
    required this.onTap,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Area Gambar ──────────────────────────────────────
            SizedBox(
              height: compact ? 68 : 110,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: item.imageUrl != null
                        ? BackendNetworkImage(
                            imageUrl: item.imageUrl!,
                            fit: BoxFit.cover,
                            memCacheWidth: 480,
                            placeholderBuilder: (ctx) =>
                                _CategoryBg(category: item.categoryName),
                            errorBuilder: (ctx) =>
                                _CategoryBg(category: item.categoryName),
                          )
                        : _CategoryBg(category: item.categoryName),
                  ),
                  if (item.isFeatured && compact)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Semantics(
                        label: 'Menu unggulan',
                        child: const Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: Color(0xFFFFC107),
                        ),
                      ),
                    ),
                  if (item.isFeatured && !compact)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Semantics(
                        label: 'Menu unggulan',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFC107),
                            borderRadius: BorderRadius.circular(99),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                size: 12,
                                color: Color(0xFF5C4100),
                              ),
                              SizedBox(width: 3),
                              Text(
                                'Unggulan',
                                style: TextStyle(
                                  color: Color(0xFF5C4100),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!item.isAvailable)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.4),
                        child: const Center(
                          child: Text(
                            'Habis',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (quantity > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _kRed,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Text(
                          '$quantity',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // ── Area Info ─────────────────────────────────────────
            Padding(
              padding: compact
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                  : const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.name,
                    style: TextStyle(
                      fontSize: compact ? 11 : 13,
                      height: compact ? 1.2 : null,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF111111),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!compact &&
                      item.description != null &&
                      item.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        item.description!,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF999999),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  SizedBox(height: compact ? 4 : 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            CurrencyFormatter.format(item.price),
                            style: TextStyle(
                              fontSize: compact ? 11 : 13,
                              height: compact ? 1.2 : null,
                              fontWeight: FontWeight.w600,
                              color: _kRed,
                            ),
                          ),
                        ),
                      ),
                      if (item.isAvailable) ...[
                        const SizedBox(width: 6),
                        if (compact)
                          GestureDetector(
                            onTap: onAdd,
                            child: const SizedBox(
                              width: 24,
                              height: 24,
                              child: Icon(
                                Icons.add_circle,
                                color: _kRed,
                                size: 24,
                              ),
                            ),
                          )
                        else
                          _QtyControl(
                            quantity: quantity,
                            onAdd: onAdd,
                            onRemove: onRemove,
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBg extends StatelessWidget {
  final String? category;
  const _CategoryBg({this.category});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ColoredBox(
        color: _categoryBg(category),
        child: const Center(
          child: Icon(
            Icons.restaurant_menu,
            size: 36,
            color: Color(0xFFCCCCCC),
          ),
        ),
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _QtyControl({
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (quantity == 0) {
      return GestureDetector(
        onTap: onAdd,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _kRed,
            borderRadius: BorderRadius.circular(99),
          ),
          child: const Icon(Icons.add, size: 16, color: Colors.white),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onRemove,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFFFECEC),
              borderRadius: BorderRadius.circular(99),
            ),
            child: const Icon(Icons.remove, size: 13, color: _kRed),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$quantity',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF111111),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onAdd,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kRed,
              borderRadius: BorderRadius.circular(99),
            ),
            child: const Icon(Icons.add, size: 13, color: Colors.white),
          ),
        ),
      ],
    );
  }
}

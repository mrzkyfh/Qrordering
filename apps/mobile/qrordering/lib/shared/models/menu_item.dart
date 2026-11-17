import 'package:equatable/equatable.dart';
import 'menu_extra.dart';

class MenuItemVariant extends Equatable {
  final String name;
  final double priceAddition;

  const MenuItemVariant({required this.name, required this.priceAddition});

  factory MenuItemVariant.fromJson(Map<String, dynamic> json) =>
      MenuItemVariant(
        name: json['name'] as String,
        priceAddition: (json['price_addition'] as num).toDouble(),
      );

  @override
  List<Object?> get props => [name, priceAddition];
}

class MenuItem extends Equatable {
  final String id;
  final String outletId;
  final String? categoryId;
  final String name;
  final String? description;
  final double price;
  final String? imageUrl;
  final bool isAvailable;
  final bool isActive;
  final bool isFeatured;
  final bool allowPriceOverride;
  final int? preparationTime;
  final List<String>? tags;
  final List<MenuItemVariant>? variants;
  final List<MenuExtra>? extras;
  final int sortOrder;
  final String? categoryName;

  const MenuItem({
    required this.id,
    required this.outletId,
    this.categoryId,
    required this.name,
    this.description,
    required this.price,
    this.imageUrl,
    required this.isAvailable,
    required this.isActive,
    required this.isFeatured,
    this.allowPriceOverride = false,
    this.preparationTime,
    this.tags,
    this.variants,
    this.extras,
    required this.sortOrder,
    this.categoryName,
  });

  factory MenuItem.fromJson(Map<String, dynamic> json) => MenuItem(
    id: json['id'] as String? ?? '',
    outletId: json['outlet_id'] as String? ?? '',
    categoryId: json['category_id'] as String?,
    name: json['name'] as String? ?? '',
    description: json['description'] as String?,
    price: (json['price'] as num?)?.toDouble() ?? 0,
    imageUrl: switch (json['image_url']) {
      final String url when url.trim().isNotEmpty => url.trim(),
      _ => null,
    },
    isAvailable: json['is_available'] as bool? ?? true,
    isActive: json['is_active'] as bool? ?? true,
    isFeatured: json['is_featured'] as bool? ?? false,
    allowPriceOverride: json['allow_price_override'] as bool? ?? false,
    preparationTime: json['preparation_time'] as int?,
    tags: (json['tags'] as List<dynamic>?)?.cast<String>(),
    variants: (json['variants'] as List<dynamic>?)
        ?.map((v) => MenuItemVariant.fromJson(v as Map<String, dynamic>))
        .toList(),
    extras: (json['menu_item_extras'] as List<dynamic>?)
        ?.map((e) => e['menu_extras'] as Map<String, dynamic>?)
        .whereType<Map<String, dynamic>>()
        .map((e) => MenuExtra.fromJson(e))
        .where((e) => e.isActive)
        .toList(),
    sortOrder: json['sort_order'] as int? ?? 0,
    categoryName:
        (json['menu_categories'] as Map<String, dynamic>?)?['name'] as String?,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    categoryId,
    price,
    imageUrl,
    isAvailable,
    isActive,
    isFeatured,
    allowPriceOverride,
    preparationTime,
    tags,
    variants,
    extras,
    sortOrder,
    categoryName,
  ];
}

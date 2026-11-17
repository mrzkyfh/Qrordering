import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../../shared/models/menu_item.dart';
import '../../../../shared/models/enums.dart';
import '../../domain/entities/cart_item.dart';
import '../../domain/entities/held_order.dart';
import '../../domain/entities/selected_extra.dart';

/// Penyimpanan lokal order ditahan per perangkat.
///
/// Data ini sengaja tidak dikirim ke Supabase: parked order hanyalah draft
/// keranjang lokal sampai kasir memilih untuk menyimpan/membayar transaksi.
class HeldOrderService {
  HeldOrderService._();

  static const boxName = 'held_orders_secure_v1';
  static const legacyBoxName = 'held_orders';
  static const _uuid = Uuid();

  static Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  static Future<void> save({
    required String outletId,
    required List<CartItem> items,
    required OrderType orderType,
    String? tableId,
    String? tableNumber,
    String? customerName,
    String? label,
  }) async {
    if (items.any((item) => item.requiresVoidToRemove)) {
      throw StateError(
        'Pesanan tersimpan tidak boleh ditahan sebagai keranjang baru.',
      );
    }
    final box = await _box();
    final now = DateTime.now();
    final cleanLabel = label?.trim();
    final fallback = customerName?.trim().isNotEmpty == true
        ? customerName!.trim()
        : tableNumber?.trim().isNotEmpty == true
        ? 'Meja ${tableNumber!.trim()}'
        : 'Pesanan ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final id = _uuid.v4();
    await box.put(id, {
      'id': id,
      'outlet_id': outletId,
      'label': cleanLabel?.isNotEmpty == true ? cleanLabel : fallback,
      'created_at': now.toIso8601String(),
      'order_type': orderType.value,
      'table_id': tableId,
      'table_number': tableNumber,
      'customer_name': customerName,
      'items': items.map(_itemToMap).toList(),
    });
  }

  static Future<List<HeldOrder>> list(String outletId) async {
    final box = await _box();
    final result = <HeldOrder>[];
    for (final raw in box.values) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      if (map['outlet_id'] != outletId) continue;
      try {
        result.add(_fromMap(map));
      } catch (_) {
        // Baris lama/rusak tidak boleh membuat daftar order ditahan gagal.
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  static Future<void> remove(String id) async {
    final box = await _box();
    await box.delete(id);
  }

  static Map<String, dynamic> _itemToMap(CartItem item) => {
    'id': item.id,
    'menu_item': {
      'id': item.menuItem.id,
      'outlet_id': item.menuItem.outletId,
      'category_id': item.menuItem.categoryId,
      'name': item.menuItem.name,
      'description': item.menuItem.description,
      'price': item.menuItem.price,
      'image_url': item.menuItem.imageUrl,
      'is_available': item.menuItem.isAvailable,
      'is_active': item.menuItem.isActive,
      'is_featured': item.menuItem.isFeatured,
      'allow_price_override': item.menuItem.allowPriceOverride,
      'preparation_time': item.menuItem.preparationTime,
      'tags': item.menuItem.tags,
      'variants': item.menuItem.variants
          ?.map((v) => {'name': v.name, 'price_addition': v.priceAddition})
          .toList(),
      'sort_order': item.menuItem.sortOrder,
      'category_name': item.menuItem.categoryName,
    },
    'quantity': item.quantity,
    'notes': item.notes,
    'overridden_price': item.overriddenPrice,
    'selected_variant': item.selectedVariant == null
        ? null
        : {
            'name': item.selectedVariant!.name,
            'price_addition': item.selectedVariant!.priceAddition,
          },
    'selected_extras': item.selectedExtras
        .map(
          (e) => {
            'menu_extra_id': e.menuExtraId,
            'menu_extra_option_id': e.menuExtraOptionId,
            'extra_name': e.extraName,
            'option_name': e.optionName,
            'price': e.price,
          },
        )
        .toList(),
  };

  static HeldOrder _fromMap(Map<String, dynamic> map) {
    final rawItems = (map['items'] as List<dynamic>? ?? const []);
    return HeldOrder(
      id: map['id'] as String,
      outletId: map['outlet_id'] as String,
      label: map['label'] as String? ?? 'Pesanan ditahan',
      createdAt: DateTime.parse(map['created_at'] as String),
      items: rawItems
          .map((raw) => _itemFromMap(Map<String, dynamic>.from(raw as Map)))
          .toList(),
      orderType: OrderTypeX.fromString(
        map['order_type'] as String? ?? 'dine_in',
      ),
      tableId: map['table_id'] as String?,
      tableNumber: map['table_number'] as String?,
      customerName: map['customer_name'] as String?,
    );
  }

  static CartItem _itemFromMap(Map<String, dynamic> map) {
    final menu = Map<String, dynamic>.from(map['menu_item'] as Map);
    final rawVariant = map['selected_variant'] as Map?;
    final rawExtras = map['selected_extras'] as List<dynamic>? ?? const [];
    return CartItem(
      id: map['id'] as String,
      menuItem: MenuItem.fromJson(menu),
      quantity: (map['quantity'] as num?)?.toInt() ?? 1,
      notes: map['notes'] as String?,
      overriddenPrice: (map['overridden_price'] as num?)?.toDouble(),
      selectedVariant: rawVariant == null
          ? null
          : MenuItemVariant.fromJson(Map<String, dynamic>.from(rawVariant)),
      selectedExtras: rawExtras.map((raw) {
        final e = Map<String, dynamic>.from(raw as Map);
        return SelectedExtra(
          menuExtraId: e['menu_extra_id'] as String? ?? '',
          menuExtraOptionId: e['menu_extra_option_id'] as String? ?? '',
          extraName: e['extra_name'] as String? ?? '',
          optionName: e['option_name'] as String? ?? '',
          price: (e['price'] as num?)?.toDouble() ?? 0,
        );
      }).toList(),
    );
  }
}

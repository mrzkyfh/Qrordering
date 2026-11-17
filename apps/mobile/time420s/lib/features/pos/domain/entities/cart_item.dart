import 'package:equatable/equatable.dart';
import '../../../../shared/models/menu_item.dart';
import 'selected_extra.dart';

class CartItem extends Equatable {
  final String id;
  final MenuItem menuItem;
  final int quantity;

  /// Quantity already recorded by the server. Only the approved void flow may
  /// reduce this amount; newly added units remain freely editable.
  final int persistedQuantity;
  final String? persistedOrderItemId;
  bool get requiresVoidToRemove => persistedQuantity > 0;
  bool get requiresVoidToDecrease => quantity <= persistedQuantity;
  final String? notes;
  final MenuItemVariant? selectedVariant;
  final List<SelectedExtra> selectedExtras;
  final double? overriddenPrice;

  const CartItem({
    required this.id,
    required this.menuItem,
    required this.quantity,
    this.persistedQuantity = 0,
    this.persistedOrderItemId,
    this.notes,
    this.selectedVariant,
    this.selectedExtras = const [],
    this.overriddenPrice,
  });

  double get extrasPrice => selectedExtras.fold(0, (sum, e) => sum + e.price);

  double get basePrice => overriddenPrice ?? menuItem.price;

  double get unitPrice =>
      basePrice + (selectedVariant?.priceAddition ?? 0) + extrasPrice;

  double get subtotal => unitPrice * quantity;

  CartItem copyWith({
    int? quantity,
    int? persistedQuantity,
    String? persistedOrderItemId,
    String? notes,
    MenuItemVariant? selectedVariant,
    List<SelectedExtra>? selectedExtras,
    double? overriddenPrice,
  }) {
    return CartItem(
      id: id,
      menuItem: menuItem,
      quantity: quantity ?? this.quantity,
      persistedQuantity: persistedQuantity ?? this.persistedQuantity,
      persistedOrderItemId: persistedOrderItemId ?? this.persistedOrderItemId,
      notes: notes ?? this.notes,
      selectedVariant: selectedVariant ?? this.selectedVariant,
      selectedExtras: selectedExtras ?? this.selectedExtras,
      overriddenPrice: overriddenPrice ?? this.overriddenPrice,
    );
  }

  @override
  List<Object?> get props => [
    id,
    menuItem.id,
    quantity,
    persistedQuantity,
    persistedOrderItemId,
    notes,
    selectedVariant,
    selectedExtras,
    overriddenPrice,
  ];
}

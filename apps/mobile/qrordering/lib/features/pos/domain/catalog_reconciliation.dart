import '../../../../shared/models/menu_item.dart';
import 'entities/cart_item.dart';
import 'entities/selected_extra.dart';

class CatalogReconciliation {
  const CatalogReconciliation({
    required this.cart,
    required this.catalog,
    required this.messages,
    required this.blocking,
    required this.changed,
  });

  final List<CartItem> cart;
  final List<MenuItem> catalog;
  final List<String> messages;
  final bool blocking;
  final bool changed;
}

/// Cocokkan snapshot keranjang dengan katalog server terbaru tanpa membuang
/// kuantitas, catatan, atau identitas baris keranjang.
CatalogReconciliation reconcileCartCatalog(
  List<CartItem> cart,
  List<MenuItem> catalog,
) {
  final byId = {for (final item in catalog) item.id: item};
  final messages = <String>[];
  final updated = <CartItem>[];
  var blocking = false;
  var changed = false;

  for (final old in cart) {
    final fresh = byId[old.menuItem.id];
    if (fresh == null || !fresh.isActive) {
      blocking = true;
      messages.add('${old.menuItem.name} sudah dihapus/nonaktif');
      updated.add(old);
      continue;
    }
    if (!fresh.isAvailable) {
      blocking = true;
      messages.add('${fresh.name} sedang tidak tersedia');
    }

    MenuItemVariant? variant;
    if (old.selectedVariant != null) {
      for (final candidate in fresh.variants ?? const <MenuItemVariant>[]) {
        if (candidate.name == old.selectedVariant!.name) {
          variant = candidate;
          break;
        }
      }
      if (variant == null) {
        blocking = true;
        messages.add(
          'Varian ${old.selectedVariant!.name} pada ${fresh.name} sudah berubah',
        );
      }
    }

    final selected = <SelectedExtra>[];
    final selectedExtraIds = <String>{};
    for (final oldExtra in old.selectedExtras) {
      SelectedExtra? replacement;
      for (final extra in fresh.extras ?? const []) {
        for (final option in extra.options) {
          if (option.id == oldExtra.menuExtraOptionId) {
            replacement = SelectedExtra(
              menuExtraId: extra.id,
              menuExtraOptionId: option.id,
              extraName: extra.name,
              optionName: option.name,
              price: option.price,
            );
            selectedExtraIds.add(extra.id);
            break;
          }
        }
        if (replacement != null) break;
      }
      if (replacement == null) {
        blocking = true;
        messages.add(
          'Pilihan ${oldExtra.optionName} pada ${fresh.name} sudah berubah',
        );
      } else {
        selected.add(replacement);
      }
    }
    for (final extra in fresh.extras ?? const []) {
      if (extra.isRequired && !selectedExtraIds.contains(extra.id)) {
        blocking = true;
        messages.add('${fresh.name} memerlukan pilihan ${extra.name}');
      }
    }
    if (old.overriddenPrice != null && !fresh.allowPriceOverride) {
      blocking = true;
      messages.add('Harga manual ${fresh.name} tidak lagi diizinkan');
    }

    final next = CartItem(
      id: old.id,
      menuItem: fresh,
      quantity: old.quantity,
      persistedQuantity: old.persistedQuantity,
      persistedOrderItemId: old.persistedOrderItemId,
      notes: old.notes,
      selectedVariant: variant,
      selectedExtras: selected,
      overriddenPrice: old.overriddenPrice,
    );
    if (next.menuItem != old.menuItem ||
        next.selectedVariant != old.selectedVariant ||
        next.selectedExtras.length != old.selectedExtras.length ||
        (next.unitPrice - old.unitPrice).abs() > 0.001) {
      changed = true;
      if ((next.unitPrice - old.unitPrice).abs() > 0.001) {
        messages.add('Harga ${fresh.name} diperbarui');
      }
    }
    updated.add(next);
  }

  return CatalogReconciliation(
    cart: updated,
    catalog: catalog,
    messages: messages.toSet().toList(),
    blocking: blocking,
    changed: changed || blocking,
  );
}

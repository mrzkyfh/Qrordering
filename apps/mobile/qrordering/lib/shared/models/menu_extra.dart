import 'package:equatable/equatable.dart';

class MenuExtraOption extends Equatable {
  final String id;
  final String extraId;
  final String name;
  final double price;
  final int sortOrder;

  const MenuExtraOption({
    required this.id,
    required this.extraId,
    required this.name,
    required this.price,
    required this.sortOrder,
  });

  factory MenuExtraOption.fromJson(Map<String, dynamic> json) =>
      MenuExtraOption(
        id: json['id'] as String,
        extraId: json['extra_id'] as String,
        name: json['name'] as String,
        price: (json['price'] as num?)?.toDouble() ?? 0,
        sortOrder: json['sort_order'] as int? ?? 0,
      );

  @override
  List<Object?> get props => [id, extraId, name, price, sortOrder];
}

class MenuExtra extends Equatable {
  final String id;
  final String outletId;
  final String name;
  final String type; // 'optional' | 'required'
  final String selectionType; // 'single' | 'multiple'
  final bool isActive;
  final int sortOrder;
  final List<MenuExtraOption> options;

  const MenuExtra({
    required this.id,
    required this.outletId,
    required this.name,
    required this.type,
    required this.selectionType,
    required this.isActive,
    required this.sortOrder,
    required this.options,
  });

  bool get isRequired => type == 'required';
  bool get isSingleSelect => selectionType == 'single';

  factory MenuExtra.fromJson(Map<String, dynamic> json) => MenuExtra(
    id: json['id'] as String,
    outletId: json['outlet_id'] as String,
    name: json['name'] as String,
    type: json['type'] as String? ?? 'optional',
    selectionType: json['selection_type'] as String? ?? 'single',
    isActive: json['is_active'] as bool? ?? true,
    sortOrder: json['sort_order'] as int? ?? 0,
    options: (json['menu_extra_options'] as List<dynamic>? ?? [])
        .map((o) => MenuExtraOption.fromJson(o as Map<String, dynamic>))
        .toList(),
  );

  @override
  List<Object?> get props => [
    id,
    outletId,
    name,
    type,
    selectionType,
    isActive,
    sortOrder,
    options,
  ];
}

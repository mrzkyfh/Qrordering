import 'package:equatable/equatable.dart';

class MenuCategory extends Equatable {
  final String id;
  final String outletId;
  final String name;
  final String? icon;
  final int sortOrder;
  final bool isActive;
  final String? departmentId;

  const MenuCategory({
    required this.id,
    required this.outletId,
    required this.name,
    this.icon,
    required this.sortOrder,
    required this.isActive,
    this.departmentId,
  });

  factory MenuCategory.fromJson(Map<String, dynamic> json) => MenuCategory(
    id: json['id'] as String,
    outletId: json['outlet_id'] as String,
    name: json['name'] as String,
    icon: json['icon'] as String?,
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    isActive: json['is_active'] as bool,
    departmentId: json['department_id'] as String?,
  );

  @override
  List<Object?> get props => [id, name, sortOrder];

  /// Urutan kanonik kategori di seluruh aplikasi.
  ///
  /// `sort_order` diatur dari owner panel. Nama hanya menjadi pembanding
  /// sekunder agar hasil stabil ketika data lama masih mempunyai nomor sama.
  static int compare(MenuCategory a, MenuCategory b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

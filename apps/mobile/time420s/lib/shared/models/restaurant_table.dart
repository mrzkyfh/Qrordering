import 'package:equatable/equatable.dart';
import 'enums.dart';

class RestaurantTable extends Equatable {
  final String id;
  final String outletId;
  final String tableNumber;
  final String? area;
  final int capacity;
  final TableStatus status;
  final String? qrToken;
  final String? qrCodeUrl;
  final bool isActive;

  const RestaurantTable({
    required this.id,
    required this.outletId,
    required this.tableNumber,
    this.area,
    required this.capacity,
    required this.status,
    this.qrToken,
    this.qrCodeUrl,
    required this.isActive,
  });

  factory RestaurantTable.fromJson(Map<String, dynamic> json) => RestaurantTable(
        id: json['id'] as String,
        outletId: json['outlet_id'] as String,
        tableNumber: json['table_number'] as String,
        area: json['area'] as String?,
        capacity: json['capacity'] as int,
        status: TableStatusX.fromString(json['status'] as String),
        qrToken: json['qr_token'] as String?,
        qrCodeUrl: json['qr_code_url'] as String?,
        isActive: json['is_active'] as bool,
      );

  @override
  List<Object?> get props => [id, tableNumber, status];
}

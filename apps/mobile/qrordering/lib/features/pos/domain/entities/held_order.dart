import 'package:equatable/equatable.dart';
import '../../../../shared/models/enums.dart';
import 'cart_item.dart';

/// Keranjang yang ditahan sementara oleh kasir.
///
/// Ini berbeda dari draft di server: held order belum menjadi transaksi dan
/// tidak mengurangi stok, belum muncul di Daftar Order, serta tetap tersedia
/// walau perangkat sedang offline.
class HeldOrder extends Equatable {
  final String id;
  final String outletId;
  final String label;
  final DateTime createdAt;
  final List<CartItem> items;
  final OrderType orderType;
  final String? tableId;
  final String? tableNumber;
  final String? customerName;

  const HeldOrder({
    required this.id,
    required this.outletId,
    required this.label,
    required this.createdAt,
    required this.items,
    required this.orderType,
    this.tableId,
    this.tableNumber,
    this.customerName,
  });

  @override
  List<Object?> get props => [
    id,
    outletId,
    label,
    createdAt,
    items,
    orderType,
    tableId,
    tableNumber,
    customerName,
  ];
}

import 'package:equatable/equatable.dart';

/// Pergerakan kas selama shift (kas masuk / kas keluar).
class CashMovement extends Equatable {
  final String id;
  final String? requestId;
  final String shiftId;
  final String outletId;
  final String type; // 'in' | 'out'
  final double amount;
  final String? note;
  final String? createdBy;
  final DateTime createdAt;

  const CashMovement({
    required this.id,
    this.requestId,
    required this.shiftId,
    required this.outletId,
    required this.type,
    required this.amount,
    this.note,
    this.createdBy,
    required this.createdAt,
  });

  bool get isIn => type == 'in';

  /// Nilai bertanda: masuk positif, keluar negatif.
  double get signedAmount => isIn ? amount : -amount;

  factory CashMovement.fromJson(Map<String, dynamic> json) => CashMovement(
    id: json['id'] as String,
    requestId: json['request_id'] as String?,
    shiftId: json['shift_id'] as String,
    outletId: json['outlet_id'] as String,
    type: json['type'] as String,
    amount: (json['amount'] as num).toDouble(),
    note: json['note'] as String?,
    createdBy: json['created_by'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'request_id': requestId,
    'shift_id': shiftId,
    'outlet_id': outletId,
    'type': type,
    'amount': amount,
    'note': note,
    'created_by': createdBy,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [id, requestId, shiftId, type, amount, createdAt];
}

import 'package:equatable/equatable.dart';

class Shift extends Equatable {
  final String id;
  final String outletId;
  final String kasirId;
  final DateTime startTime;
  final DateTime? endTime;
  final double openingCash;
  final double? closingCash;
  final double? expectedCash;
  final double? cashDifference;
  final String? notes;
  final String? cashierName;

  const Shift({
    required this.id,
    required this.outletId,
    required this.kasirId,
    required this.startTime,
    this.endTime,
    required this.openingCash,
    this.closingCash,
    this.expectedCash,
    this.cashDifference,
    this.notes,
    this.cashierName,
  });

  bool get isOpen => endTime == null;

  factory Shift.fromJson(Map<String, dynamic> json) {
    final staff = json['staff'];
    return Shift(
      id: json['id'] as String,
      outletId: json['outlet_id'] as String,
      kasirId: json['kasir_id'] as String,
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: json['end_time'] != null
          ? DateTime.parse(json['end_time'] as String)
          : null,
      openingCash: (json['opening_cash'] as num).toDouble(),
      closingCash: json['closing_cash'] != null
          ? (json['closing_cash'] as num).toDouble()
          : null,
      expectedCash: json['expected_cash'] != null
          ? (json['expected_cash'] as num).toDouble()
          : null,
      cashDifference: json['cash_difference'] != null
          ? (json['cash_difference'] as num).toDouble()
          : null,
      notes: json['notes'] as String?,
      cashierName:
          json['cashier_name'] as String? ??
          (staff is Map ? staff['full_name'] as String? : null),
    );
  }

  @override
  List<Object?> get props => [id, kasirId, startTime, isOpen, cashierName];
}

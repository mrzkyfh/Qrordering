import 'package:equatable/equatable.dart';
import '../services/receipt_builder.dart';

class ShiftPaymentSummary extends Equatable {
  final String method;
  final double amount;

  const ShiftPaymentSummary({required this.method, required this.amount});

  factory ShiftPaymentSummary.fromJson(Map<String, dynamic> json) =>
      ShiftPaymentSummary(
        method: json['method'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );

  @override
  List<Object?> get props => [method, amount];
}

class ShiftProductSummary extends Equatable {
  final String name;
  final int quantity;
  final double amount;

  const ShiftProductSummary({
    required this.name,
    required this.quantity,
    required this.amount,
  });

  factory ShiftProductSummary.fromJson(Map<String, dynamic> json) =>
      ShiftProductSummary(
        name: json['name'] as String? ?? 'Menu',
        quantity: (json['quantity'] as num?)?.toInt() ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );

  @override
  List<Object?> get props => [name, quantity, amount];
}

class ShiftExpenseSummary extends Equatable {
  final String id;
  final String category;
  final String description;
  final double amount;
  final DateTime createdAt;

  const ShiftExpenseSummary({
    required this.id,
    required this.category,
    required this.description,
    required this.amount,
    required this.createdAt,
  });

  factory ShiftExpenseSummary.fromJson(Map<String, dynamic> json) =>
      ShiftExpenseSummary(
        id: json['id'] as String? ?? '',
        category: json['category'] as String? ?? 'lain_lain',
        description: json['description'] as String? ?? 'Pengeluaran kasir',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  List<Object?> get props => [id, category, description, amount, createdAt];
}

/// Snapshot laporan yang dikembalikan server sesaat setelah shift ditutup.
class ShiftCloseReport extends Equatable {
  final String shiftId;
  final String outletId;
  final OutletReceiptInfo outlet;
  final String cashierId;
  final String cashierName;
  final DateTime openedAt;
  final DateTime closedAt;
  final double openingCash;
  final double closingCash;
  final double expectedCash;
  final double cashDifference;
  final double cashReceived;
  final double nonCashReceived;
  final double totalReceipts;
  final double taxTotal;
  final double serviceChargeTotal;
  final double discountTotal;
  final double refundTotal;
  final double cashIn;
  final double cashOut;
  final int completedTransactions;
  final int unpaidTransactions;
  final int voidItemQuantity;
  final double voidItemAmount;
  final int productQuantity;
  final List<ShiftPaymentSummary> paymentMethods;
  final List<ShiftProductSummary> products;
  final List<ShiftExpenseSummary> expenses;
  final String? notes;
  final bool isProvisional;

  const ShiftCloseReport({
    required this.shiftId,
    required this.outletId,
    required this.outlet,
    required this.cashierId,
    required this.cashierName,
    required this.openedAt,
    required this.closedAt,
    required this.openingCash,
    required this.closingCash,
    required this.expectedCash,
    required this.cashDifference,
    required this.cashReceived,
    required this.nonCashReceived,
    required this.totalReceipts,
    required this.taxTotal,
    required this.serviceChargeTotal,
    required this.discountTotal,
    required this.refundTotal,
    required this.cashIn,
    required this.cashOut,
    required this.completedTransactions,
    required this.unpaidTransactions,
    required this.voidItemQuantity,
    required this.voidItemAmount,
    required this.productQuantity,
    required this.paymentMethods,
    required this.products,
    this.expenses = const [],
    this.notes,
    this.isProvisional = false,
  });

  factory ShiftCloseReport.fromJson(Map<String, dynamic> json) {
    final outletJson = Map<String, dynamic>.from(
      json['outlet'] as Map? ?? const {},
    );
    return ShiftCloseReport(
      shiftId: json['shift_id'] as String? ?? '',
      outletId: json['outlet_id'] as String? ?? '',
      outlet: OutletReceiptInfo.fromMap(outletJson),
      cashierId: json['cashier_id'] as String? ?? '',
      cashierName: json['cashier_name'] as String? ?? 'Kasir',
      openedAt: DateTime.parse(json['opened_at'] as String),
      closedAt: DateTime.parse(json['closed_at'] as String),
      openingCash: (json['opening_cash'] as num?)?.toDouble() ?? 0,
      closingCash: (json['closing_cash'] as num?)?.toDouble() ?? 0,
      expectedCash: (json['expected_cash'] as num?)?.toDouble() ?? 0,
      cashDifference: (json['cash_difference'] as num?)?.toDouble() ?? 0,
      cashReceived: (json['cash_received'] as num?)?.toDouble() ?? 0,
      nonCashReceived: (json['non_cash_received'] as num?)?.toDouble() ?? 0,
      totalReceipts: (json['total_receipts'] as num?)?.toDouble() ?? 0,
      taxTotal: (json['tax_total'] as num?)?.toDouble() ?? 0,
      serviceChargeTotal:
          (json['service_charge_total'] as num?)?.toDouble() ?? 0,
      discountTotal: (json['discount_total'] as num?)?.toDouble() ?? 0,
      refundTotal: (json['refund_total'] as num?)?.toDouble() ?? 0,
      cashIn: (json['cash_in'] as num?)?.toDouble() ?? 0,
      cashOut: (json['cash_out'] as num?)?.toDouble() ?? 0,
      completedTransactions:
          (json['completed_transactions'] as num?)?.toInt() ?? 0,
      unpaidTransactions: (json['unpaid_transactions'] as num?)?.toInt() ?? 0,
      voidItemQuantity: (json['void_item_quantity'] as num?)?.toInt() ?? 0,
      voidItemAmount: (json['void_item_amount'] as num?)?.toDouble() ?? 0,
      productQuantity: (json['product_quantity'] as num?)?.toInt() ?? 0,
      paymentMethods: (json['payment_methods'] as List? ?? const [])
          .map(
            (entry) => ShiftPaymentSummary.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList(),
      products: (json['products'] as List? ?? const [])
          .map(
            (entry) => ShiftProductSummary.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList(),
      expenses: (json['expenses'] as List? ?? const [])
          .map(
            (entry) => ShiftExpenseSummary.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList(),
      notes: json['notes'] as String?,
      isProvisional: json['_provisional'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [
    shiftId,
    closedAt,
    closingCash,
    expectedCash,
    cashDifference,
    paymentMethods,
    products,
    expenses,
    isProvisional,
  ];
}

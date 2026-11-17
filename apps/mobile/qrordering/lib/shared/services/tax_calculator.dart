import 'package:equatable/equatable.dart';

/// Satu aturan pajak yang disimpan owner-panel di `outlets.settings.taxes`.
class TaxRule extends Equatable {
  final String id;
  final String name;
  final double percent;
  final bool active;
  final bool inclusive;
  final String calculation;
  final Set<String> orderTypes;

  const TaxRule({
    this.id = '',
    this.name = '',
    this.percent = 0,
    this.active = true,
    this.inclusive = false,
    this.calculation = 'before_discount',
    this.orderTypes = const {},
  });

  factory TaxRule.fromMap(Map<dynamic, dynamic> map) => TaxRule(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    percent: (map['percent'] as num?)?.toDouble() ?? 0,
    active: map['active'] is bool ? map['active'] as bool : true,
    inclusive: map['inclusive'] is bool ? map['inclusive'] as bool : false,
    calculation: map['calculation'] == 'after_discount'
        ? 'after_discount'
        : 'before_discount',
    orderTypes: map['order_types'] is List
        ? (map['order_types'] as List).map((e) => e.toString()).toSet()
        : const {},
  );

  bool appliesTo(String orderType) =>
      orderTypes.isEmpty || orderTypes.contains(orderType);

  @override
  List<Object?> get props => [
    id,
    name,
    percent,
    active,
    inclusive,
    calculation,
    orderTypes,
  ];
}

class TaxComputation {
  final double total;
  final double addedToTotal;
  final double includedInPrice;

  const TaxComputation({
    required this.total,
    required this.addedToTotal,
    required this.includedInPrice,
  });
}

/// Menghitung seluruh aturan pajak aktif pada dasar yang sama.
///
/// `orders` hanya memiliki satu flag `tax_inclusive`. Jika konfigurasi
/// mencampur pajak inclusive dan exclusive, semua pajak diperlakukan sebagai
/// tambahan total agar tidak ada bagian pajak yang hilang. Dengan begitu hasil
/// mobile tetap sama dengan invariant server; owner sebaiknya memakai mode
/// penerapan yang sama untuk semua rule.
TaxComputation computeTaxes({
  required double subtotal,
  double discountAmount = 0,
  double loyaltyDiscount = 0,
  required List<TaxRule> rules,
  required String orderType,
}) {
  var total = 0.0;
  var included = 0.0;
  var added = 0.0;

  for (final rule in rules) {
    if (!rule.active || rule.percent <= 0 || !rule.appliesTo(orderType)) {
      continue;
    }
    final taxable = rule.calculation == 'after_discount'
        ? (subtotal - discountAmount - loyaltyDiscount)
              .clamp(0.0, double.infinity)
              .toDouble()
        : subtotal;
    final amount = rule.inclusive
        ? (taxable - taxable / (1 + rule.percent / 100)).roundToDouble()
        : (taxable * rule.percent / 100).roundToDouble();
    total += amount;
    if (rule.inclusive) {
      included += amount;
    } else {
      added += amount;
    }
  }

  final mixedModes = included > 0 && added > 0;
  return TaxComputation(
    total: total,
    addedToTotal: mixedModes ? total : added,
    includedInPrice: mixedModes ? 0 : included,
  );
}

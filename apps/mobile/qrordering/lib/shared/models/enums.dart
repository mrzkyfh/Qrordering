enum UserRole { owner, admin, manajer, kasir, pelanggan }

enum OrderStatus { draft, confirmed, preparing, ready, served, paid, cancelled, void_ }

enum PaymentMethod { cash, qris, debit, credit, ewallet, transfer }

enum TableStatus { available, occupied, reserved, dirty }

enum StockTransactionType { purchase, usage, adjustment, waste, return_ }

enum PromoType { percentage, fixed, bundling, bogo }

enum ExpenseCategory { bahanBaku, operasional, gaji, peralatan, marketing, lainLain }

enum OrderType { dineIn, takeaway, selfOrder }

extension UserRoleX on UserRole {
  /// Owner, admin, dan manajer dapat memakai seluruh fitur administrasi outlet.
  bool get hasAdminAccess =>
      this == UserRole.owner ||
      this == UserRole.admin ||
      this == UserRole.manajer;

  String get value => switch (this) {
        UserRole.owner => 'owner',
        UserRole.admin => 'admin',
        UserRole.manajer => 'manajer',
        UserRole.kasir => 'kasir',
        UserRole.pelanggan => 'pelanggan',
      };
  static UserRole fromString(String v) =>
      UserRole.values.firstWhere((e) => e.value == v, orElse: () => UserRole.kasir);
}

extension OrderStatusX on OrderStatus {
  String get value => switch (this) {
        OrderStatus.draft => 'draft',
        OrderStatus.confirmed => 'confirmed',
        OrderStatus.preparing => 'preparing',
        OrderStatus.ready => 'ready',
        OrderStatus.served => 'served',
        OrderStatus.paid => 'paid',
        OrderStatus.cancelled => 'cancelled',
        OrderStatus.void_ => 'void',
      };
  static OrderStatus fromString(String v) =>
      OrderStatus.values.firstWhere((e) => e.value == v, orElse: () => OrderStatus.draft);

  String get label => switch (this) {
        OrderStatus.draft => 'Draft',
        OrderStatus.confirmed => 'Dikonfirmasi',
        OrderStatus.preparing => 'Dimasak',
        OrderStatus.ready => 'Siap',
        OrderStatus.served => 'Disajikan',
        OrderStatus.paid => 'Lunas',
        OrderStatus.cancelled => 'Dibatalkan',
        OrderStatus.void_ => 'Void',
      };
}

extension PaymentMethodX on PaymentMethod {
  String get value => switch (this) {
        PaymentMethod.cash => 'cash',
        PaymentMethod.qris => 'qris',
        PaymentMethod.debit => 'debit',
        PaymentMethod.credit => 'credit',
        PaymentMethod.ewallet => 'ewallet',
        PaymentMethod.transfer => 'transfer',
      };
  static PaymentMethod fromString(String v) =>
      PaymentMethod.values.firstWhere((e) => e.value == v, orElse: () => PaymentMethod.cash);

  String get label => switch (this) {
        PaymentMethod.cash => 'Tunai',
        PaymentMethod.qris => 'QRIS',
        PaymentMethod.debit => 'Kartu Debit',
        PaymentMethod.credit => 'Kartu Kredit',
        PaymentMethod.ewallet => 'E-Wallet',
        PaymentMethod.transfer => 'Transfer Bank',
      };
}

extension TableStatusX on TableStatus {
  String get value => switch (this) {
        TableStatus.available => 'available',
        TableStatus.occupied => 'occupied',
        TableStatus.reserved => 'reserved',
        TableStatus.dirty => 'dirty',
      };
  static TableStatus fromString(String v) =>
      TableStatus.values.firstWhere((e) => e.value == v, orElse: () => TableStatus.available);
}

extension OrderTypeX on OrderType {
  String get value => switch (this) {
        OrderType.dineIn => 'dine_in',
        OrderType.takeaway => 'takeaway',
        OrderType.selfOrder => 'self_order',
      };
  static OrderType fromString(String v) =>
      OrderType.values.firstWhere((e) => e.value == v, orElse: () => OrderType.dineIn);
}

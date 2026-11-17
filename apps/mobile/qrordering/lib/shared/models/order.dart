import 'package:equatable/equatable.dart';
import 'enums.dart';
import 'menu_item.dart';

/// Extra/topping terpilih pada satu order item (snapshot nama+harga saat
/// order dibuat). Sumber: tabel `order_item_options`.
class OrderItemOption extends Equatable {
  final String extraName;
  final String optionName;
  final double price;

  const OrderItemOption({
    required this.extraName,
    required this.optionName,
    required this.price,
  });

  factory OrderItemOption.fromJson(Map<String, dynamic> json) =>
      OrderItemOption(
        extraName: json['extra_name'] as String? ?? '',
        optionName: json['option_name'] as String? ?? '',
        price: (json['price'] as num?)?.toDouble() ?? 0,
      );

  @override
  List<Object?> get props => [extraName, optionName, price];
}

class OrderItem extends Equatable {
  final String id;
  final String orderId;
  final String menuItemId;
  final int quantity;
  final double unitPrice;
  final double subtotal;
  final String? notes;
  final MenuItem? menuItem;
  final List<OrderItemOption> options;

  const OrderItem({
    required this.id,
    required this.orderId,
    required this.menuItemId,
    required this.quantity,
    required this.unitPrice,
    required this.subtotal,
    this.notes,
    this.menuItem,
    this.options = const [],
  });

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
    id: json['id'] as String,
    orderId: json['order_id'] as String,
    menuItemId: json['menu_item_id'] as String,
    quantity: json['quantity'] as int,
    unitPrice: (json['unit_price'] as num).toDouble(),
    subtotal: (json['subtotal'] as num).toDouble(),
    notes: json['notes'] as String?,
    menuItem: json['menu_items'] != null
        ? MenuItem.fromJson(json['menu_items'] as Map<String, dynamic>)
        : null,
    options:
        (json['order_item_options'] as List<dynamic>?)
            ?.map((e) => OrderItemOption.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  @override
  List<Object?> get props => [id, menuItemId, quantity, subtotal];
}

class Payment extends Equatable {
  final String id;
  final String orderId;
  final String outletId;
  final PaymentMethod method;
  final double amount;
  final String? referenceNumber;
  final DateTime paidAt;

  const Payment({
    required this.id,
    required this.orderId,
    required this.outletId,
    required this.method,
    required this.amount,
    this.referenceNumber,
    required this.paidAt,
  });

  // Tolerant terhadap select parsial (mis. `payments(id)` untuk cek keberadaan
  // pembayaran) — field yang tak diminta diberi nilai default.
  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
    id: json['id'] as String? ?? '',
    orderId: json['order_id'] as String? ?? '',
    outletId: json['outlet_id'] as String? ?? '',
    method: PaymentMethodX.fromString(json['method'] as String? ?? 'cash'),
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    referenceNumber: json['reference_number'] as String?,
    paidAt: json['paid_at'] != null
        ? DateTime.parse(json['paid_at'] as String)
        : DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  List<Object?> get props => [id, orderId, amount];
}

class Order extends Equatable {
  final String id;
  final String outletId;
  final String? shiftId;
  final String? tableId;
  final String orderNumber;
  final OrderType orderType;
  final OrderStatus status;
  final String? customerName;
  final String? notes;
  final double subtotal;
  final double discountAmount;
  final double taxAmount;
  final double serviceCharge;
  final double totalAmount;
  final bool stockDeducted;
  final bool kitchenPrinted;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<OrderItem>? items;
  final List<Payment>? payments;
  final String? tableNumber;

  const Order({
    required this.id,
    required this.outletId,
    this.shiftId,
    this.tableId,
    required this.orderNumber,
    required this.orderType,
    required this.status,
    this.customerName,
    this.notes,
    required this.subtotal,
    required this.discountAmount,
    required this.taxAmount,
    required this.serviceCharge,
    required this.totalAmount,
    required this.stockDeducted,
    this.kitchenPrinted = false,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.items,
    this.payments,
    this.tableNumber,
  });

  factory Order.fromJson(Map<String, dynamic> json) => Order(
    id: json['id'] as String,
    outletId: json['outlet_id'] as String,
    shiftId: json['shift_id'] as String?,
    tableId: json['table_id'] as String?,
    orderNumber: json['order_number'] as String? ?? '',
    orderType: OrderTypeX.fromString(
      json['order_type'] as String? ?? 'dine_in',
    ),
    status: OrderStatusX.fromString(json['status'] as String? ?? 'confirmed'),
    customerName: json['customer_name'] as String?,
    notes: json['notes'] as String?,
    subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
    discountAmount: (json['discount_amount'] as num?)?.toDouble() ?? 0,
    taxAmount: (json['tax_amount'] as num?)?.toDouble() ?? 0,
    serviceCharge: (json['service_charge'] as num?)?.toDouble() ?? 0,
    totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0,
    stockDeducted: json['stock_deducted'] as bool? ?? false,
    kitchenPrinted: json['kitchen_printed'] as bool? ?? false,
    createdBy: json['created_by'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    items: (json['order_items'] as List<dynamic>?)
        ?.map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
        .toList(),
    payments: (json['payments'] as List<dynamic>?)
        ?.map((e) => Payment.fromJson(e as Map<String, dynamic>))
        .toList(),
    tableNumber:
        (json['restaurant_tables'] as Map<String, dynamic>?)?['table_number']
            as String?,
  );

  bool get isActive => ![
    OrderStatus.paid,
    OrderStatus.cancelled,
    OrderStatus.void_,
  ].contains(status);

  /// True bila pembayaran sudah tercatat (model bayar-di-depan). Dipakai untuk
  /// menandai order yang sudah lunas tapi masih diproses dapur, agar tidak
  /// diminta bayar lagi di kasir & otomatis jadi `paid` saat disajikan.
  bool get hasPayment => (payments?.isNotEmpty ?? false);

  /// Total nominal pembayaran yang sudah tercatat (butuh select `payments(amount)`).
  double get paidTotal =>
      payments?.fold<double>(0, (s, p) => s + p.amount) ?? 0;

  /// True bila tagihan sudah tertutup penuh (status paid ATAU jumlah pembayaran
  /// ≥ total). Dipakai untuk tombol "Lunas" — beda dari [hasPayment] yang bisa
  /// true walau baru bayar sebagian (split bill).
  bool get isFullyPaid =>
      status == OrderStatus.paid || paidTotal >= totalAmount - 0.01;

  /// Mode layanan untuk order QR disimpan sebagai baris pertama catatan order.
  /// Format ini tetap kompatibel dengan server lama yang belum memiliki kolom
  /// mode layanan tersendiri, tetapi cukup ketat agar catatan pelanggan biasa
  /// tidak keliru dianggap sebagai pilihan layanan.
  String? get customerServiceMode {
    if (orderType != OrderType.selfOrder || notes == null) return null;
    final firstLine = notes!.split('\n').first.trim().toLowerCase();
    if (firstLine == 'jenis layanan: bawa pulang') return 'pickup';
    if (firstLine.startsWith('jenis layanan: makan di tempat')) {
      return 'dine_in';
    }
    return null;
  }

  String? get customerServiceLabel => switch (customerServiceMode) {
    'pickup' => 'Bawa Pulang',
    'dine_in' =>
      tableNumber == null || tableNumber!.trim().isEmpty
          ? 'Makan di Tempat'
          : 'Makan di Tempat · Meja ${tableNumber!.trim()}',
    _ => null,
  };

  /// Label operasional yang dipakai konsisten pada struk pelanggan dan tiket
  /// dapur. `self_order` saja tidak cukup karena QR meja juga dapat dipilih
  /// sebagai bawa pulang.
  String get operationalOrderTypeLabel => switch (orderType) {
    OrderType.dineIn => 'Dine In',
    OrderType.takeaway => 'Bawa Pulang',
    OrderType.selfOrder => switch (customerServiceMode) {
      'pickup' => 'QR - Bawa Pulang',
      'dine_in' => 'QR - Makan di Tempat',
      _ => 'Order QR',
    },
  };

  /// QR bawa pulang tetap berasal dari sebuah token meja, tetapi nomor meja
  /// tersebut hanya sumber capability dan bukan tujuan penyajian. Untuk order
  /// QR lama yang belum menyimpan baris mode layanan, tetap tampilkan meja agar
  /// informasi operasional tidak hilang.
  bool get shouldDisplayTable =>
      tableNumber?.trim().isNotEmpty == true &&
      !(orderType == OrderType.selfOrder && customerServiceMode == 'pickup');

  /// Catatan yang benar-benar ditulis pelanggan/staf, tanpa baris metadata
  /// `Jenis layanan: ...` yang disisipkan menu QR pada baris pertama.
  String? get customerOrderNote {
    final raw = notes?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (orderType != OrderType.selfOrder || customerServiceMode == null) {
      return raw;
    }
    final lines = raw.split('\n');
    if (lines.isNotEmpty) lines.removeAt(0);
    final note = lines.join('\n').trim();
    return note.isEmpty ? null : note;
  }

  @override
  List<Object?> get props => [
    id,
    orderNumber,
    status,
    totalAmount,
    updatedAt,
    // hasPayment menentukan tombol "Lunas". Pembayaran masuk ke tabel
    // `payments` (bukan mengubah orders.updated_at), jadi `payments` HARUS
    // ada di props agar UI rebuild saat order dibayar (bayar-di-depan).
    payments,
    customerName,
    notes,
    tableNumber,
  ];
}

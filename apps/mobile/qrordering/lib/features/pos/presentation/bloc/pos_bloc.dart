import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';
import '../../../../shared/models/menu_item.dart';
import '../../../../shared/models/menu_category.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/tax_calculator.dart';
import '../../domain/entities/cart_item.dart';
import '../../domain/entities/selected_extra.dart';
import '../../domain/catalog_reconciliation.dart';
import '../../data/datasources/pos_datasource.dart';

// ─── Events ───────────────────────────────────────────────────────────────────

abstract class PosEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class PosMenuLoadRequested extends PosEvent {
  final String outletId;
  PosMenuLoadRequested(this.outletId);
  @override
  List<Object?> get props => [outletId];
}

class PosCatalogReconciled extends PosEvent {
  final CatalogReconciliation result;
  PosCatalogReconciled(this.result);
  @override
  List<Object?> get props => [result.cart, result.catalog];
}

class PosCategorySelected extends PosEvent {
  final String? categoryId;
  PosCategorySelected(this.categoryId);
  @override
  List<Object?> get props => [categoryId];
}

class PosItemAdded extends PosEvent {
  final MenuItem item;
  final MenuItemVariant? variant;
  final List<SelectedExtra> selectedExtras;
  final int quantity;
  final String? notes;
  final double? overriddenPrice;
  PosItemAdded(
    this.item, {
    this.variant,
    this.selectedExtras = const [],
    this.quantity = 1,
    this.notes,
    this.overriddenPrice,
  });
  @override
  List<Object?> get props => [
    item.id,
    variant,
    selectedExtras,
    quantity,
    notes,
    overriddenPrice,
  ];
}

class PosItemRemoved extends PosEvent {
  final String cartItemId;
  PosItemRemoved(this.cartItemId);
  @override
  List<Object?> get props => [cartItemId];
}

class PosQuantityChanged extends PosEvent {
  final String cartItemId;
  final int delta;
  PosQuantityChanged(this.cartItemId, this.delta);
  @override
  List<Object?> get props => [cartItemId, delta];
}

class PosNotesChanged extends PosEvent {
  final String cartItemId;
  final String notes;
  PosNotesChanged(this.cartItemId, this.notes);
  @override
  List<Object?> get props => [cartItemId, notes];
}

class PosOrderTypeChanged extends PosEvent {
  final OrderType orderType;
  PosOrderTypeChanged(this.orderType);
  @override
  List<Object?> get props => [orderType];
}

class PosTableSelected extends PosEvent {
  final String? tableId;
  final String? tableNumber;
  PosTableSelected(this.tableId, this.tableNumber);
  @override
  List<Object?> get props => [tableId];
}

// Internal reset after saving/payment or explicitly leaving an editing session.
class PosCartCleared extends PosEvent {}

/// Keluar dari mode tambah pesanan lama dan mulai transaksi baru yang aman.
///
/// Reset ini sengaja berbeda dari [PosCartCleared]: meja dan tipe order induk
/// tidak boleh terbawa ke pelanggan berikutnya. Takeaway dipilih sebagai
/// kondisi awal tanpa meja; kasir tetap dapat menggantinya ke Dine In.
class PosAppendCancelled extends PosEvent {}

// User-requested deletion must never clear persisted items without void.
class PosCartRemovalRequested extends PosEvent {}

/// Applies a server-approved item void to an open edit cart. The order item ID
/// is kept separately from the local cart row ID so stale rows cannot survive
/// after they have been removed from Daftar Order.
class PosPersistedItemsVoided extends PosEvent {
  final String orderId;
  final Map<String, int> remainingByOrderItemId;
  final bool orderVoided;

  PosPersistedItemsVoided(
    this.orderId,
    this.remainingByOrderItemId, {
    this.orderVoided = false,
  });

  @override
  List<Object?> get props => [orderId, remainingByOrderItemId, orderVoided];
}

class PosCustomerNameChanged extends PosEvent {
  final String name;
  PosCustomerNameChanged(this.name);
  @override
  List<Object?> get props => [name];
}

/// Muat ulang isi keranjang dari sebuah order (untuk "Edit"/recall draf).
/// Bila [appendOrderId] diisi → masuk mode "tambah pesanan" (item akan
/// ditambahkan ke order itu, biasanya dengan keranjang awal kosong).
/// Bila [replaceOrderId] diisi → item pesanan online yang belum diproses akan
/// diganti secara atomik pada order yang sama.
class PosCartLoaded extends PosEvent {
  final List<CartItem> items;
  final OrderType orderType;
  final String? tableId;
  final String? tableNumber;
  final String? appendOrderId;
  final String? appendOrderNumber;
  final String? customerName;
  final String? editingOrderId;
  final String? editingOrderNumber;
  final String? replaceOrderId;
  final String? replaceOrderNumber;
  PosCartLoaded(
    this.items, {
    this.orderType = OrderType.dineIn,
    this.tableId,
    this.tableNumber,
    this.appendOrderId,
    this.appendOrderNumber,
    this.customerName,
    this.editingOrderId,
    this.editingOrderNumber,
    this.replaceOrderId,
    this.replaceOrderNumber,
  });
  @override
  List<Object?> get props => [
    items,
    orderType,
    tableId,
    tableNumber,
    appendOrderId,
    appendOrderNumber,
    customerName,
    editingOrderId,
    editingOrderNumber,
    replaceOrderId,
    replaceOrderNumber,
  ];
}

class PosSearchChanged extends PosEvent {
  final String query;
  PosSearchChanged(this.query);
  @override
  List<Object?> get props => [query];
}

class PosPromoApplied extends PosEvent {
  final String code;
  final String outletId;
  PosPromoApplied(this.code, {required this.outletId});
  @override
  List<Object?> get props => [code, outletId];
}

class PosPromoRemoved extends PosEvent {}

class PosLoyaltyLookup extends PosEvent {
  final String phone;
  final String outletId;
  PosLoyaltyLookup(this.phone, {required this.outletId});
  @override
  List<Object?> get props => [phone, outletId];
}

class PosLoyaltyCleared extends PosEvent {}

class PosLoyaltyRedeem extends PosEvent {
  final int points;
  PosLoyaltyRedeem(this.points);
  @override
  List<Object?> get props => [points];
}

class PosLoyaltyRedeemCleared extends PosEvent {}

// ─── States ───────────────────────────────────────────────────────────────────

class PosState extends Equatable {
  final bool menuLoading;
  final String? menuError;
  final List<MenuCategory> categories;
  final List<MenuItem> menuItems;
  final String loadedOutletId; // outlet pemilik menu yang sedang dimuat
  final String? selectedCategoryId;
  final String searchQuery;
  final List<CartItem> cart;
  final OrderType orderType;
  final String? tableId;
  final String? tableNumber;
  final String? customerName;
  final double discountAmount;
  final String? promoCode;
  final String? promoId;
  final String? voucherId;
  final bool promoLoading;
  final String? promoError;
  final String? loyaltyMemberId;
  final String? loyaltyMemberName;
  final String? loyaltyMemberPhone;
  final int loyaltyMemberPoints;
  final bool loyaltyLoading;
  final String? loyaltyError;
  final double loyaltyDiscount;
  final int redeemedPoints;
  final bool redeemLoading;
  final String? redeemError;
  final bool submitting;
  final String? submitError;
  final String? submittedOrderId;

  /// Stable id for the current unsent POS mutation. The database uses it as
  /// p_order_id so retrying after a lost response returns the same order.
  final String? transactionRequestId;
  // Setting outlet (dari owner panel) untuk hitung pajak & service charge.
  final double taxPercent;
  final bool taxActive;

  /// Harga menu sudah termasuk pajak → pajak dipisahkan, bukan ditambahkan.
  final bool taxInclusive;
  final String taxCalculation;
  final Set<String> taxOrderTypes;
  final List<TaxRule> taxRules;
  final double serviceChargePercent;

  /// Metode pembayaran outlet yang aktif. Tunai selalu dipaksa aktif agar
  /// outlet tidak kehilangan jalur pembayaran terakhirnya.
  final Set<String> enabledPaymentMethods;

  /// Nominal pembulatan total; 0 berarti tidak ada pembulatan.
  final int rounding;
  // Mode "tambah pesanan" (open bill): bila terisi, item di keranjang akan
  // DITAMBAHKAN ke order ini (bukan buat order baru).
  final String? appendOrderId;
  final String? appendOrderNumber;
  // Mode edit draf: order lama dipertahankan sampai order pengganti berhasil
  // dibuat. Ini mencegah order hilang saat kasir membatalkan/mengosongkan cart.
  final String? editingOrderId;
  final String? editingOrderNumber;
  // Mode edit pesanan online confirmed: seluruh isi order diganti oleh cart
  // melalui RPC atomik, tanpa membuat nomor order baru.
  final String? replaceOrderId;
  final String? replaceOrderNumber;

  const PosState({
    this.menuLoading = false,
    this.menuError,
    this.categories = const [],
    this.menuItems = const [],
    this.loadedOutletId = '',
    this.selectedCategoryId,
    this.searchQuery = '',
    this.cart = const [],
    this.orderType = OrderType.dineIn,
    this.tableId,
    this.tableNumber,
    this.customerName,
    this.discountAmount = 0,
    this.promoCode,
    this.promoId,
    this.voucherId,
    this.promoLoading = false,
    this.promoError,
    this.loyaltyMemberId,
    this.loyaltyMemberName,
    this.loyaltyMemberPhone,
    this.loyaltyMemberPoints = 0,
    this.loyaltyLoading = false,
    this.loyaltyError,
    this.loyaltyDiscount = 0,
    this.redeemedPoints = 0,
    this.redeemLoading = false,
    this.redeemError,
    this.submitting = false,
    this.submitError,
    this.submittedOrderId,
    this.transactionRequestId,
    this.taxPercent = 0,
    this.taxActive = true,
    this.taxInclusive = false,
    this.taxCalculation = 'before_discount',
    this.taxOrderTypes = const {},
    this.taxRules = const [],
    this.serviceChargePercent = 0,
    this.enabledPaymentMethods = const {
      'cash',
      'qris',
      'debit',
      'credit',
      'ewallet',
      'transfer',
    },
    this.rounding = 0,
    this.appendOrderId,
    this.appendOrderNumber,
    this.editingOrderId,
    this.editingOrderNumber,
    this.replaceOrderId,
    this.replaceOrderNumber,
  });

  List<MenuItem> get filteredMenu {
    var items = selectedCategoryId == null
        ? List<MenuItem>.of(menuItems)
        : menuItems.where((m) => m.categoryId == selectedCategoryId).toList();
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      items = items.where((m) => m.name.toLowerCase().contains(q)).toList();
    }
    items.sort((a, b) {
      final featured = (b.isFeatured ? 1 : 0).compareTo(a.isFeatured ? 1 : 0);
      if (featured != 0) return featured;
      final order = a.sortOrder.compareTo(b.sortOrder);
      if (order != 0) return order;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  /// Jangan bergantung pada urutan respons jaringan/cache. Owner mengatur
  /// posisi kategori melalui `sort_order` di web dan aplikasi wajib selalu
  /// menghormatinya, termasuk ketika sedang memakai cache offline.
  List<MenuCategory> get sortedCategories =>
      List<MenuCategory>.of(categories)..sort(MenuCategory.compare);

  double get subtotal => cart.fold(0, (sum, i) => sum + i.subtotal);

  /// Pajak & service charge dihitung atas subtotal (sebelum diskon), mengikuti
  /// perhitungan kanonik server (create_self_order): round(subtotal × persen/100).
  ///
  /// [taxInclusive] = harga menu SUDAH memuat pajak. Maka pajak tidak ditambahkan
  /// lagi, melainkan DIPISAHKAN dari harga (subtotal − subtotal/(1+p)) untuk
  /// ditampilkan di struk ("Harga Sudah Termasuk PPN senilai X"). Struk sudah
  /// lama menghormati mode ini, tapi perhitungan di sini dulu mengabaikannya:
  /// pajak tetap ditambahkan di atas → pelanggan tertagih dobel sementara
  /// struknya menyatakan pajak sudah termasuk.
  TaxComputation get _taxes => computeTaxes(
    subtotal: subtotal,
    discountAmount: discountAmount,
    loyaltyDiscount: loyaltyDiscount,
    rules: taxRules.isNotEmpty
        ? taxRules
        : [
            TaxRule(
              percent: taxPercent,
              active: taxActive,
              inclusive: taxInclusive,
              calculation: taxCalculation,
              orderTypes: taxOrderTypes,
            ),
          ],
    orderType: orderType.value,
  );

  double get taxAmount => _taxes.total;

  /// Flag snapshot order-level. Mixed inclusive/exclusive rules harus false
  /// karena kolom database hanya punya satu flag dan total wajib menambahkan
  /// seluruh pajaknya.
  bool get taxInclusiveForOrder => taxAmount > 0 && _taxes.addedToTotal == 0;

  double get serviceCharge =>
      (subtotal * serviceChargePercent / 100).roundToDouble();

  double get unroundedTotal =>
      (subtotal - discountAmount - loyaltyDiscount).clamp(0, double.infinity) +
      _taxes.addedToTotal +
      serviceCharge;

  /// Total = (subtotal − diskon − loyalty) + pajak + service charge.
  /// Saat harga sudah termasuk pajak, komponen pajak TIDAK ditambahkan lagi —
  /// ia sudah ada di dalam subtotal.
  double get total {
    if (rounding <= 0) return unroundedTotal;
    return (unroundedTotal / rounding).round() * rounding.toDouble();
  }

  int get itemCount => cart.fold(0, (sum, i) => sum + i.quantity);

  PosState copyWith({
    bool? menuLoading,
    String? menuError,
    bool clearMenuError = false,
    List<MenuCategory>? categories,
    List<MenuItem>? menuItems,
    String? loadedOutletId,
    String? selectedCategoryId,
    bool clearCategory = false,
    List<CartItem>? cart,
    OrderType? orderType,
    String? tableId,
    String? tableNumber,
    bool clearTable = false,
    String? customerName,
    bool clearCustomerName = false,
    double? discountAmount,
    String? promoCode,
    String? promoId,
    String? voucherId,
    bool? promoLoading,
    String? promoError,
    bool clearPromo = false,
    bool clearPromoError = false,
    String? loyaltyMemberId,
    String? loyaltyMemberName,
    String? loyaltyMemberPhone,
    int? loyaltyMemberPoints,
    bool? loyaltyLoading,
    String? loyaltyError,
    bool clearLoyalty = false,
    bool clearLoyaltyError = false,
    double? loyaltyDiscount,
    int? redeemedPoints,
    bool? redeemLoading,
    String? redeemError,
    bool clearRedeem = false,
    bool clearRedeemError = false,
    bool? submitting,
    String? searchQuery,
    String? submitError,
    String? submittedOrderId,
    bool clearSubmit = false,
    String? transactionRequestId,
    bool clearTransactionRequest = false,
    double? taxPercent,
    bool? taxActive,
    bool? taxInclusive,
    String? taxCalculation,
    Set<String>? taxOrderTypes,
    List<TaxRule>? taxRules,
    double? serviceChargePercent,
    Set<String>? enabledPaymentMethods,
    int? rounding,
    String? appendOrderId,
    String? appendOrderNumber,
    bool clearAppend = false,
    String? editingOrderId,
    String? editingOrderNumber,
    bool clearEditing = false,
    String? replaceOrderId,
    String? replaceOrderNumber,
    bool clearReplace = false,
  }) {
    return PosState(
      menuLoading: menuLoading ?? this.menuLoading,
      menuError: clearMenuError ? null : (menuError ?? this.menuError),
      categories: categories ?? this.categories,
      menuItems: menuItems ?? this.menuItems,
      loadedOutletId: loadedOutletId ?? this.loadedOutletId,
      selectedCategoryId: clearCategory
          ? null
          : (selectedCategoryId ?? this.selectedCategoryId),
      searchQuery: searchQuery ?? this.searchQuery,
      cart: cart ?? this.cart,
      orderType: orderType ?? this.orderType,
      tableId: clearTable ? null : (tableId ?? this.tableId),
      tableNumber: clearTable ? null : (tableNumber ?? this.tableNumber),
      customerName: clearCustomerName
          ? null
          : (customerName ?? this.customerName),
      discountAmount: clearPromo ? 0 : (discountAmount ?? this.discountAmount),
      promoCode: clearPromo ? null : (promoCode ?? this.promoCode),
      promoId: clearPromo ? null : (promoId ?? this.promoId),
      voucherId: clearPromo ? null : (voucherId ?? this.voucherId),
      promoLoading: promoLoading ?? this.promoLoading,
      promoError: clearPromoError ? null : (promoError ?? this.promoError),
      loyaltyMemberId: clearLoyalty
          ? null
          : (loyaltyMemberId ?? this.loyaltyMemberId),
      loyaltyMemberName: clearLoyalty
          ? null
          : (loyaltyMemberName ?? this.loyaltyMemberName),
      loyaltyMemberPhone: clearLoyalty
          ? null
          : (loyaltyMemberPhone ?? this.loyaltyMemberPhone),
      loyaltyMemberPoints: clearLoyalty
          ? 0
          : (loyaltyMemberPoints ?? this.loyaltyMemberPoints),
      loyaltyLoading: loyaltyLoading ?? this.loyaltyLoading,
      loyaltyError: clearLoyaltyError
          ? null
          : (loyaltyError ?? this.loyaltyError),
      loyaltyDiscount: (clearLoyalty || clearRedeem)
          ? 0
          : (loyaltyDiscount ?? this.loyaltyDiscount),
      redeemedPoints: (clearLoyalty || clearRedeem)
          ? 0
          : (redeemedPoints ?? this.redeemedPoints),
      redeemLoading: redeemLoading ?? this.redeemLoading,
      redeemError: clearRedeemError ? null : (redeemError ?? this.redeemError),
      submitting: submitting ?? this.submitting,
      submitError: submitError ?? this.submitError,
      submittedOrderId: clearSubmit
          ? null
          : (submittedOrderId ?? this.submittedOrderId),
      transactionRequestId: clearTransactionRequest
          ? null
          : (transactionRequestId ?? this.transactionRequestId),
      taxPercent: taxPercent ?? this.taxPercent,
      taxActive: taxActive ?? this.taxActive,
      taxInclusive: taxInclusive ?? this.taxInclusive,
      taxCalculation: taxCalculation ?? this.taxCalculation,
      taxOrderTypes: taxOrderTypes ?? this.taxOrderTypes,
      taxRules: taxRules ?? this.taxRules,
      serviceChargePercent: serviceChargePercent ?? this.serviceChargePercent,
      enabledPaymentMethods:
          enabledPaymentMethods ?? this.enabledPaymentMethods,
      rounding: rounding ?? this.rounding,
      appendOrderId: clearAppend ? null : (appendOrderId ?? this.appendOrderId),
      appendOrderNumber: clearAppend
          ? null
          : (appendOrderNumber ?? this.appendOrderNumber),
      editingOrderId: clearEditing
          ? null
          : (editingOrderId ?? this.editingOrderId),
      editingOrderNumber: clearEditing
          ? null
          : (editingOrderNumber ?? this.editingOrderNumber),
      replaceOrderId: clearReplace
          ? null
          : (replaceOrderId ?? this.replaceOrderId),
      replaceOrderNumber: clearReplace
          ? null
          : (replaceOrderNumber ?? this.replaceOrderNumber),
    );
  }

  @override
  List<Object?> get props => [
    menuLoading,
    menuError,
    categories,
    menuItems,
    loadedOutletId,
    selectedCategoryId,
    searchQuery,
    cart,
    orderType,
    tableId,
    tableNumber,
    customerName,
    discountAmount,
    promoCode,
    promoId,
    voucherId,
    promoLoading,
    promoError,
    loyaltyMemberId,
    loyaltyMemberName,
    loyaltyMemberPhone,
    loyaltyMemberPoints,
    loyaltyLoading,
    loyaltyError,
    loyaltyDiscount,
    redeemedPoints,
    redeemLoading,
    redeemError,
    submitting,
    submitError,
    submittedOrderId,
    transactionRequestId,
    taxPercent,
    taxActive,
    taxInclusive,
    taxCalculation,
    taxOrderTypes,
    taxRules,
    serviceChargePercent,
    enabledPaymentMethods,
    rounding,
    appendOrderId,
    appendOrderNumber,
    editingOrderId,
    editingOrderNumber,
    replaceOrderId,
    replaceOrderNumber,
  ];
}

// ─── BLoC ─────────────────────────────────────────────────────────────────────

class PosBloc extends Bloc<PosEvent, PosState> {
  final PosDatasource datasource;
  final _uuid = const Uuid();

  PosBloc({required this.datasource}) : super(const PosState()) {
    on<PosMenuLoadRequested>(_onMenuLoad);
    on<PosCatalogReconciled>(_onCatalogReconciled);
    on<PosCategorySelected>(_onCategorySelected);
    on<PosItemAdded>(_onItemAdded);
    on<PosItemRemoved>(_onItemRemoved);
    on<PosQuantityChanged>(_onQuantityChanged);
    on<PosNotesChanged>(_onNotesChanged);
    on<PosOrderTypeChanged>(_onOrderTypeChanged);
    on<PosTableSelected>(_onTableSelected);
    on<PosCartCleared>(_onCartCleared);
    on<PosAppendCancelled>(_onAppendCancelled);
    on<PosCartRemovalRequested>((event, emit) {
      if (state.cart.any((item) => item.requiresVoidToRemove)) return;
      _onCartCleared(PosCartCleared(), emit);
    });
    on<PosPersistedItemsVoided>(_onPersistedItemsVoided);
    on<PosCustomerNameChanged>(_onCustomerNameChanged);
    on<PosCartLoaded>(_onCartLoaded);
    on<PosSearchChanged>(_onSearchChanged);
    on<PosPromoApplied>(_onPromoApplied);
    on<PosPromoRemoved>(_onPromoRemoved);
    on<PosLoyaltyLookup>(_onLoyaltyLookup);
    on<PosLoyaltyCleared>(_onLoyaltyCleared);
    on<PosLoyaltyRedeem>(_onLoyaltyRedeem);
    on<PosLoyaltyRedeemCleared>(_onLoyaltyRedeemCleared);
  }

  Future<void> _onMenuLoad(
    PosMenuLoadRequested event,
    Emitter<PosState> emit,
  ) async {
    // Guard: outletId kosong → query uuid '' crash. Beri pesan jelas.
    if (event.outletId.trim().isEmpty) {
      emit(
        state.copyWith(
          menuLoading: false,
          menuError:
              'Akun ini belum terhubung ke outlet. Hubungi admin untuk mengatur outlet.',
        ),
      );
      return;
    }
    emit(state.copyWith(menuLoading: true, clearMenuError: true));
    try {
      final categories = await datasource.fetchCategories(event.outletId);
      final items = await datasource.fetchMenuItems(event.outletId);
      final settings = await datasource.fetchOutletSettings(event.outletId);
      final rules = _taxRules(settings);
      final primary = rules.isNotEmpty ? rules.first : const TaxRule();
      emit(
        state.copyWith(
          menuLoading: false,
          clearMenuError: true,
          categories: categories,
          menuItems: items,
          loadedOutletId: event.outletId,
          // Setting pajak & service charge dari owner panel.
          taxPercent: primary.percent,
          taxActive: primary.active,
          taxInclusive: primary.inclusive,
          taxCalculation: primary.calculation,
          taxOrderTypes: primary.orderTypes,
          taxRules: rules,
          serviceChargePercent:
              (settings['service_charge_percent'] as num?)?.toDouble() ?? 0,
          enabledPaymentMethods: _enabledPaymentMethods(settings),
          rounding: _rounding(settings),
          // Reset pilihan kategori & keranjang saat ganti outlet.
          clearCategory: true,
          cart: const [],
        ),
      );
    } catch (e) {
      emit(state.copyWith(menuLoading: false, menuError: e.toString()));
    }
  }

  void _onCatalogReconciled(
    PosCatalogReconciled event,
    Emitter<PosState> emit,
  ) {
    final freshById = {for (final item in event.result.catalog) item.id: item};
    final mergedMenu = state.menuItems
        .map((item) => freshById[item.id] ?? item)
        .toList();
    emit(
      state.copyWith(
        cart: event.result.cart,
        menuItems: mergedMenu,
        // Promo/redeem dihitung dari subtotal lama. Setelah harga katalog
        // berubah, kasir wajib menerapkannya ulang terhadap total terbaru.
        clearPromo: true,
        clearRedeem: true,
      ),
    );
  }

  static Set<String> _enabledPaymentMethods(Map<String, dynamic> settings) {
    const all = {'cash', 'qris', 'debit', 'credit', 'ewallet', 'transfer'};
    final raw = settings['payment_methods'];
    if (raw is! List) return all;
    final active = raw.map((e) => e.toString()).where(all.contains).toSet();
    active.add('cash');
    return active;
  }

  static int _rounding(Map<String, dynamic> settings) {
    final value = (settings['rounding'] as num?)?.toInt() ?? 0;
    return {0, 100, 500, 1000}.contains(value) ? value : 0;
  }

  static List<TaxRule> _taxRules(Map<String, dynamic> settings) {
    final taxes = settings['taxes'];
    if (taxes is List && taxes.isNotEmpty) {
      final rules = taxes.whereType<Map>().map(TaxRule.fromMap).toList();
      if (rules.isNotEmpty) return rules;
    }
    return [
      TaxRule(
        id: 'legacy',
        name: settings['tax_name']?.toString() ?? '',
        percent: (settings['tax_percent'] as num?)?.toDouble() ?? 0,
        active: settings['tax_active'] as bool? ?? true,
        inclusive: settings['tax_inclusive'] as bool? ?? false,
        calculation: settings['tax_calculation'] == 'after_discount'
            ? 'after_discount'
            : 'before_discount',
        orderTypes: settings['tax_order_types'] is List
            ? (settings['tax_order_types'] as List)
                  .map((e) => e.toString())
                  .toSet()
            : const {},
      ),
    ];
  }

  void _onCategorySelected(PosCategorySelected event, Emitter<PosState> emit) {
    emit(
      state.copyWith(
        selectedCategoryId: event.categoryId,
        clearCategory: event.categoryId == null,
      ),
    );
  }

  /// Diskon promo/redeem divalidasi terhadap subtotal SAAT diterapkan. Begitu
  /// keranjang berubah nominalnya basi — subtotal bisa turun di bawah minimum
  /// promo, atau diskon persen tidak dihitung ulang — jadi validasi ulang ke
  /// server; bila tak lagi valid, lepas diskonnya (jangan diam-diam dipakai).
  Future<void> _revalidateDiscounts(Emitter<PosState> emit) async {
    if (state.promoCode != null && state.loadedOutletId.isNotEmpty) {
      if (state.cart.isEmpty) {
        emit(state.copyWith(clearPromo: true));
      } else {
        try {
          final result = await datasource.validatePromo(
            code: state.promoCode!,
            outletId: state.loadedOutletId,
            subtotal: state.subtotal,
          );
          emit(
            state.copyWith(
              promoId: result['promo_id'] as String?,
              voucherId: result['voucher_id'] as String?,
              discountAmount:
                  (result['discount_amount'] as num?)?.toDouble() ?? 0,
            ),
          );
        } catch (e) {
          final msg = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
          emit(state.copyWith(clearPromo: true, promoError: msg));
        }
      }
    }
    if (state.redeemedPoints > 0 && state.loyaltyMemberId != null) {
      if (state.cart.isEmpty) {
        emit(state.copyWith(clearRedeem: true));
      } else {
        try {
          final result = await datasource.validateLoyaltyRedeem(
            memberId: state.loyaltyMemberId!,
            points: state.redeemedPoints,
            subtotal: state.subtotal,
            promoDiscount: state.discountAmount,
          );
          emit(
            state.copyWith(
              loyaltyDiscount:
                  (result['discount_amount'] as num?)?.toDouble() ?? 0,
              redeemedPoints: (result['points_used'] as num?)?.toInt() ?? 0,
            ),
          );
        } catch (e) {
          final msg = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
          emit(state.copyWith(clearRedeem: true, redeemError: msg));
        }
      }
    }
  }

  Future<void> _onItemAdded(PosItemAdded event, Emitter<PosState> emit) async {
    if (event.quantity <= 0) return;
    // Pertahanan terakhir untuk semua pemanggil, bukan hanya tombol menu.
    // Item berkonfigurasi wajib tidak boleh masuk keranjang tanpa pilihan
    // lengkap karena transaksi offline baru diperiksa server saat sinkron.
    final variants = event.item.variants ?? const <MenuItemVariant>[];
    if (variants.isNotEmpty && event.variant == null) return;
    for (final extra in event.item.extras ?? const []) {
      if (extra.isRequired &&
          !event.selectedExtras.any(
            (selected) => selected.menuExtraId == extra.id,
          )) {
        return;
      }
    }
    if (event.overriddenPrice != null &&
        (!event.item.allowPriceOverride ||
            !event.overriddenPrice!.isFinite ||
            event.overriddenPrice! <= 0)) {
      return;
    }

    // Item dengan extra ATAU catatan = entri unik (jangan digabung).
    final hasExtras = event.selectedExtras.isNotEmpty;
    final hasNotes = event.notes?.trim().isNotEmpty ?? false;
    final existing = (hasExtras || hasNotes)
        ? null
        : state.cart
              .where(
                (c) =>
                    c.menuItem.id == event.item.id &&
                    c.selectedVariant == event.variant &&
                    c.overriddenPrice == event.overriddenPrice &&
                    c.selectedExtras.isEmpty &&
                    (c.notes == null || c.notes!.isEmpty),
              )
              .firstOrNull;

    List<CartItem> newCart;
    if (existing != null) {
      newCart = state.cart
          .map(
            (c) => c.id == existing.id
                ? c.copyWith(quantity: c.quantity + event.quantity)
                : c,
          )
          .toList();
    } else {
      newCart = [
        ...state.cart,
        CartItem(
          id: _uuid.v4(),
          menuItem: event.item,
          quantity: event.quantity,
          selectedVariant: event.variant,
          selectedExtras: event.selectedExtras,
          overriddenPrice: event.overriddenPrice,
          notes: event.notes?.trim().isEmpty ?? true
              ? null
              : event.notes!.trim(),
        ),
      ];
    }
    emit(
      state.copyWith(
        cart: newCart,
        transactionRequestId: state.transactionRequestId ?? _uuid.v4(),
      ),
    );
    await _revalidateDiscounts(emit);
  }

  Future<void> _onItemRemoved(
    PosItemRemoved event,
    Emitter<PosState> emit,
  ) async {
    if (state.cart.any(
      (item) => item.id == event.cartItemId && item.requiresVoidToRemove,
    )) {
      return;
    }
    emit(
      state.copyWith(
        cart: state.cart.where((c) => c.id != event.cartItemId).toList(),
      ),
    );
    await _revalidateDiscounts(emit);
  }

  Future<void> _onQuantityChanged(
    PosQuantityChanged event,
    Emitter<PosState> emit,
  ) async {
    final target = state.cart
        .where((item) => item.id == event.cartItemId)
        .firstOrNull;
    if (target == null ||
        target.quantity + event.delta < target.persistedQuantity) {
      return;
    }
    final newCart = state.cart
        .map((c) {
          if (c.id != event.cartItemId) return c;
          final newQty = c.quantity + event.delta;
          return newQty <= 0 ? null : c.copyWith(quantity: newQty);
        })
        .whereType<CartItem>()
        .toList();
    emit(state.copyWith(cart: newCart));
    await _revalidateDiscounts(emit);
  }

  void _onNotesChanged(PosNotesChanged event, Emitter<PosState> emit) {
    emit(
      state.copyWith(
        cart: state.cart
            .map(
              (c) =>
                  c.id == event.cartItemId ? c.copyWith(notes: event.notes) : c,
            )
            .toList(),
      ),
    );
  }

  void _onOrderTypeChanged(PosOrderTypeChanged event, Emitter<PosState> emit) {
    // Tipe layanan milik order induk tidak dapat diubah oleh RPC append.
    // Mengizinkan tab berubah hanya membuat kasir merasa sedang membuat order
    // baru, padahal item tetap masuk ke order lama.
    if (state.appendOrderId != null) return;
    emit(
      state.copyWith(
        orderType: event.orderType,
        clearTable: event.orderType != OrderType.dineIn,
      ),
    );
  }

  void _onTableSelected(PosTableSelected event, Emitter<PosState> emit) {
    emit(
      state.copyWith(tableId: event.tableId, tableNumber: event.tableNumber),
    );
  }

  void _onCartCleared(PosCartCleared event, Emitter<PosState> emit) {
    emit(
      state.copyWith(
        cart: [],
        orderType: OrderType.dineIn,
        clearPromo: true,
        clearLoyalty: true,
        clearCustomerName: true,
        clearCategory: false,
        // Identitas meja/order lama tidak boleh terbawa ke pelanggan berikut.
        // Kasir harus memilih meja lagi untuk transaksi Dine In yang baru.
        clearTable: true,
        clearAppend: true, // keluar dari mode tambah pesanan
        clearEditing: true,
        clearReplace: true,
        clearTransactionRequest: true,
      ),
    );
  }

  void _onAppendCancelled(PosAppendCancelled event, Emitter<PosState> emit) {
    if (state.appendOrderId == null) return;
    emit(
      state.copyWith(
        cart: [],
        orderType: OrderType.takeaway,
        clearTable: true,
        clearPromo: true,
        clearLoyalty: true,
        clearCustomerName: true,
        clearAppend: true,
        clearEditing: true,
        clearReplace: true,
        clearTransactionRequest: true,
      ),
    );
  }

  void _onCustomerNameChanged(
    PosCustomerNameChanged event,
    Emitter<PosState> emit,
  ) {
    final name = event.name.trim();
    emit(
      name.isEmpty
          ? state.copyWith(clearCustomerName: true)
          : state.copyWith(customerName: name),
    );
  }

  void _onCartLoaded(PosCartLoaded event, Emitter<PosState> emit) {
    emit(
      state.copyWith(
        cart: event.editingOrderId != null || event.replaceOrderId != null
            ? event.items
                  .map(
                    (item) => item.copyWith(persistedQuantity: item.quantity),
                  )
                  .toList()
            : event.items,
        orderType: event.orderType,
        tableId: event.tableId,
        tableNumber: event.tableNumber,
        customerName: event.customerName,
        clearCustomerName: event.customerName == null,
        clearPromo: true,
        clearLoyalty: true,
        appendOrderId: event.appendOrderId,
        appendOrderNumber: event.appendOrderNumber,
        clearAppend: event.appendOrderId == null,
        editingOrderId: event.editingOrderId,
        editingOrderNumber: event.editingOrderNumber,
        clearEditing: event.editingOrderId == null,
        replaceOrderId: event.replaceOrderId,
        replaceOrderNumber: event.replaceOrderNumber,
        clearReplace: event.replaceOrderId == null,
        transactionRequestId: _uuid.v4(),
      ),
    );
  }

  void _onPersistedItemsVoided(
    PosPersistedItemsVoided event,
    Emitter<PosState> emit,
  ) {
    final editingSameOrder =
        state.editingOrderId == event.orderId ||
        state.replaceOrderId == event.orderId ||
        state.appendOrderId == event.orderId;
    if (!editingSameOrder) return;
    if (event.orderVoided) {
      _onCartCleared(PosCartCleared(), emit);
      return;
    }

    final updated = <CartItem>[];
    for (final item in state.cart) {
      final orderItemId = item.persistedOrderItemId;
      if (orderItemId == null) {
        updated.add(item);
        continue;
      }
      // The RPC result only contains rows touched by this void. Other saved
      // rows must remain unchanged in the open edit cart.
      if (!event.remainingByOrderItemId.containsKey(orderItemId)) {
        updated.add(item);
        continue;
      }
      final remaining = event.remainingByOrderItemId[orderItemId]!;
      final unsavedQuantity = item.quantity - item.persistedQuantity;
      if (remaining > 0 || unsavedQuantity > 0) {
        updated.add(
          item.copyWith(
            quantity: remaining + unsavedQuantity,
            persistedQuantity: remaining,
          ),
        );
      }
    }

    if (updated.isEmpty) {
      _onCartCleared(PosCartCleared(), emit);
      return;
    }
    emit(state.copyWith(cart: updated));
  }

  Future<void> _onPromoApplied(
    PosPromoApplied event,
    Emitter<PosState> emit,
  ) async {
    if (event.code.trim().isEmpty) return;
    emit(state.copyWith(promoLoading: true, clearPromoError: true));
    try {
      final result = await datasource.validatePromo(
        code: event.code.trim(),
        outletId: event.outletId,
        subtotal: state.subtotal,
      );
      emit(
        state.copyWith(
          promoLoading: false,
          promoCode: event.code.trim(),
          promoId: result['promo_id'] as String?,
          voucherId: result['voucher_id'] as String?,
          discountAmount: (result['discount_amount'] as num?)?.toDouble() ?? 0,
        ),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      emit(state.copyWith(promoLoading: false, promoError: msg));
    }
  }

  void _onPromoRemoved(PosPromoRemoved event, Emitter<PosState> emit) {
    emit(state.copyWith(clearPromo: true, clearPromoError: true));
  }

  Future<void> _onLoyaltyLookup(
    PosLoyaltyLookup event,
    Emitter<PosState> emit,
  ) async {
    if (event.phone.trim().isEmpty) return;
    emit(state.copyWith(loyaltyLoading: true, clearLoyaltyError: true));
    try {
      final result = await datasource.findLoyaltyMember(
        phone: event.phone.trim(),
        outletId: event.outletId,
      );
      if (result == null) {
        emit(
          state.copyWith(
            loyaltyLoading: false,
            loyaltyError: 'Member tidak ditemukan',
          ),
        );
        return;
      }
      emit(
        state.copyWith(
          loyaltyLoading: false,
          loyaltyMemberId: result['id'] as String?,
          loyaltyMemberName: result['name'] as String? ?? '-',
          loyaltyMemberPhone: result['phone'] as String?,
          loyaltyMemberPoints: (result['points'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      emit(state.copyWith(loyaltyLoading: false, loyaltyError: msg));
    }
  }

  void _onLoyaltyCleared(PosLoyaltyCleared event, Emitter<PosState> emit) {
    emit(state.copyWith(clearLoyalty: true, clearLoyaltyError: true));
  }

  Future<void> _onLoyaltyRedeem(
    PosLoyaltyRedeem event,
    Emitter<PosState> emit,
  ) async {
    if (state.loyaltyMemberId == null) {
      emit(state.copyWith(redeemError: 'Pilih member dulu sebelum redeem'));
      return;
    }
    if (event.points <= 0) {
      emit(state.copyWith(clearRedeem: true, clearRedeemError: true));
      return;
    }
    emit(state.copyWith(redeemLoading: true, clearRedeemError: true));
    try {
      final result = await datasource.validateLoyaltyRedeem(
        memberId: state.loyaltyMemberId!,
        points: event.points,
        subtotal: state.subtotal,
        promoDiscount: state.discountAmount,
      );
      emit(
        state.copyWith(
          redeemLoading: false,
          loyaltyDiscount: (result['discount_amount'] as num?)?.toDouble() ?? 0,
          redeemedPoints: (result['points_used'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      emit(state.copyWith(redeemLoading: false, redeemError: msg));
    }
  }

  void _onLoyaltyRedeemCleared(
    PosLoyaltyRedeemCleared event,
    Emitter<PosState> emit,
  ) {
    emit(state.copyWith(clearRedeem: true, clearRedeemError: true));
  }

  void _onSearchChanged(PosSearchChanged event, Emitter<PosState> emit) {
    emit(state.copyWith(searchQuery: event.query));
  }
}

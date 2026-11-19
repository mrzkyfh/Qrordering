import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/services/tax_calculator.dart';
import '../../../../shared/services/backend_request.dart';
import '../../../../shared/widgets/backend_network_image.dart';

@visibleForTesting
String? selfOrderMemberPhoneOrNull(String input) {
  final value = input.trim();
  return value.isEmpty ? null : value;
}

@visibleForTesting
bool isValidSelfOrderMemberPhone(String? phone) {
  if (phone == null) return true;
  final digitCount = RegExp(r'\d').allMatches(phone).length;
  return digitCount >= 8 && digitCount <= 16;
}

/// Perhitungan uang keranjang pelanggan (QR self-order).
///
/// Dipisah dari widget & dibuka untuk test dengan sengaja: ini adalah CERMIN
/// dari `create_self_order` di server (migration 114), dan pernah melenceng
/// diam-diam — membaca kunci setelan yang tidak pernah ditulis siapa pun
/// sehingga jatuh ke tarif hardcoded 11%/5%, lalu mengabaikan pajak inklusif.
/// Akibatnya pelanggan melihat total yang berbeda dari yang disimpan server.
/// Rumus di sini WAJIB identik dengan server & `PosState.total`.
@visibleForTesting
class CustomerCartTotals {
  final double subtotal;

  /// Komponen pajak. Saat harga sudah memuat pajak, ini nilai yang DIPISAHKAN
  /// dari harga (untuk ditampilkan), bukan yang ditambahkan.
  final double tax;
  final double service;
  final double total;

  const CustomerCartTotals({
    required this.subtotal,
    required this.tax,
    required this.service,
    required this.total,
  });

  factory CustomerCartTotals.compute({
    required double subtotal,
    required double taxPercent,
    required double servicePercent,
    required bool taxInclusive,
    int rounding = 0,
    String taxCalculation = 'before_discount',
    Set<String> taxOrderTypes = const {},
    List<TaxRule> taxRules = const [],
    String orderType = 'self_order',
  }) {
    // Customer self-order saat ini tidak punya diskon di keranjang; diskon
    // promo/member divalidasi dan dihitung server setelah submit.
    final rules = taxRules.isNotEmpty
        ? taxRules
        : [
            TaxRule(
              percent: taxPercent,
              inclusive: taxInclusive,
              calculation: taxCalculation,
              orderTypes: taxOrderTypes,
            ),
          ];
    final taxes = computeTaxes(
      subtotal: subtotal,
      rules: rules,
      orderType: orderType,
    );
    final service = (subtotal * servicePercent / 100).roundToDouble();
    final rawTotal = subtotal + taxes.addedToTotal + service;
    final total = rounding > 0
        ? (rawTotal / rounding).round() * rounding.toDouble()
        : rawTotal;
    return CustomerCartTotals(
      subtotal: subtotal,
      tax: taxes.total,
      service: service,
      total: total,
    );
  }
}

/// Cermin ringan dari jam order online di database. Dipakai agar pelanggan
/// mendapat pesan yang jelas sebelum menekan tombol kirim; trigger database
/// tetap menjadi pengaman terakhir.
@visibleForTesting
bool selfOrderWithinSchedule(Map<String, dynamic> settings, DateTime now) {
  if (settings['self_order_schedule_enabled'] != true) return true;
  final open = _selfOrderTime(settings['self_order_open_time'], 10 * 60);
  final close = _selfOrderTime(settings['self_order_close_time'], 22 * 60);
  if (open == close) return true;
  final current = now.hour * 60 + now.minute;
  return open < close
      ? current >= open && current < close
      : current >= open || current < close;
}

int _selfOrderTime(dynamic value, int fallback) {
  if (value is! String) return fallback;
  final parts = value.split(':');
  if (parts.length != 2) return fallback;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null || hour > 23 || minute > 59) {
    return fallback;
  }
  return hour * 60 + minute;
}

bool _isMissingPublicMenuSnapshot(Object error) {
  if (error is! PostgrestException) return false;
  return error.code == 'PGRST202' ||
      error.message.contains('get_public_menu_snapshot') ||
      error.message.contains('schema cache');
}

int _compareCategoryRows(Map<String, dynamic> a, Map<String, dynamic> b) {
  final byOrder = ((a['sort_order'] as num?)?.toInt() ?? 0).compareTo(
    (b['sort_order'] as num?)?.toInt() ?? 0,
  );
  if (byOrder != 0) return byOrder;
  return (a['name'] as String? ?? '').toLowerCase().compareTo(
    (b['name'] as String? ?? '').toLowerCase(),
  );
}

List<Map<String, dynamic>> _sortedCategoryRows(Iterable<dynamic> rows) {
  final result = rows
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  result.sort(_compareCategoryRows);
  return result;
}

// ── Entry point ───────────────────────────────────────────────────────────────

class CustomerMenuPage extends StatefulWidget {
  final String tableToken;
  const CustomerMenuPage({super.key, required this.tableToken});

  @override
  State<CustomerMenuPage> createState() => _CustomerMenuPageState();
}

class _CustomerMenuPageState extends State<CustomerMenuPage> {
  final _client = Supabase.instance.client;

  bool _resolving = true;
  String? _resolveError;
  Map<String, dynamic>? _tableData;
  Map<String, dynamic>? _outletData;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _menuItems = [];

  @override
  void initState() {
    super.initState();
    _resolveToken();
  }

  Future<void> _resolveToken() async {
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      Map<String, dynamic>? snapshot;
      try {
        final result = await _client.rpc(
          'get_public_menu_snapshot',
          params: {'p_token': widget.tableToken},
        );
        snapshot = (result as Map?)?.cast<String, dynamic>();
      } catch (error) {
        if (!_isMissingPublicMenuSnapshot(error)) rethrow;
      }
      snapshot ??= await _loadLegacySnapshot();

      final tableData = (snapshot?['table'] as Map?)?.cast<String, dynamic>();
      final outletData = (snapshot?['outlet'] as Map?)?.cast<String, dynamic>();
      if (tableData == null || outletData == null) {
        setState(() {
          _resolveError = 'Meja tidak ditemukan atau tidak aktif.';
          _resolving = false;
        });
        return;
      }

      final publicSettings = (outletData['settings'] as Map?)
          ?.cast<String, dynamic>();
      if (publicSettings?['self_order_enabled'] == false) {
        setState(() {
          _resolveError = 'Pesanan online sedang ditutup oleh outlet.';
          _resolving = false;
        });
        return;
      }
      if (publicSettings != null &&
          !selfOrderWithinSchedule(publicSettings, DateTime.now())) {
        setState(() {
          _resolveError =
              (publicSettings['self_order_closed_message'] as String?)
                      ?.trim()
                      .isNotEmpty ==
                  true
              ? publicSettings['self_order_closed_message'] as String
              : 'Order online sedang tutup. Silakan datang langsung.';
          _resolving = false;
        });
        return;
      }
      setState(() {
        _tableData = tableData;
        _outletData = outletData;
        _categories = _sortedCategoryRows(
          snapshot?['categories'] as List? ?? const [],
        );
        _menuItems = (snapshot?['menu'] as List? ?? const [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        _resolving = false;
      });
    } catch (e) {
      setState(() {
        _resolveError = e.toString();
        _resolving = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _loadLegacySnapshot() async {
    final rpcResult = await _client.rpc(
      'resolve_table_by_token',
      params: {'p_token': widget.tableToken},
    );
    final tableData = (rpcResult as Map?)?.cast<String, dynamic>();
    if (tableData == null) return null;

    final outletData = await _client
        .from('v_outlets_public')
        .select('id, name, address, phone, city, logo_url, is_active, settings')
        .eq('id', tableData['outlet_id'] as String)
        .maybeSingle();
    if (outletData == null) return null;

    final results = await Future.wait([
      _client
          .from('menu_categories')
          .select('id, name, icon, sort_order')
          .eq('outlet_id', tableData['outlet_id'] as String)
          .eq('is_active', true)
          .order('sort_order')
          .order('name'),
      _client
          .from('menu_items')
          .select(
            'id, name, price, image_url, category_id, description, '
            'is_featured, sort_order',
          )
          .eq('outlet_id', tableData['outlet_id'] as String)
          .eq('is_available', true)
          .eq('is_active', true)
          .order('is_featured', ascending: false)
          .order('sort_order')
          .order('name'),
    ]);
    return {
      'table': tableData,
      'outlet': Map<String, dynamic>.from(outletData),
      'categories': results[0],
      'menu': results[1],
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_resolving) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_resolveError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.qr_code_2,
                  size: 64,
                  color: AppColors.textDisabled,
                ),
                const SizedBox(height: 16),
                Text(
                  _resolveError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _resolveToken,
                  child: const Text('Coba lagi'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _EMenuScreen(
      tableToken: widget.tableToken,
      tableData: _tableData!,
      outletData: _outletData!,
      initialCategories: _categories,
      initialMenuItems: _menuItems,
    );
  }
}

// ── E-Menu Screen ─────────────────────────────────────────────────────────────

class _EMenuScreen extends StatefulWidget {
  final String tableToken;
  final Map<String, dynamic> tableData;
  final Map<String, dynamic> outletData;
  final List<Map<String, dynamic>> initialCategories;
  final List<Map<String, dynamic>> initialMenuItems;
  const _EMenuScreen({
    required this.tableToken,
    required this.tableData,
    required this.outletData,
    required this.initialCategories,
    required this.initialMenuItems,
  });

  @override
  State<_EMenuScreen> createState() => _EMenuScreenState();
}

class _EMenuScreenState extends State<_EMenuScreen> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _menuItems = [];
  String? _selectedCategoryId;
  final Map<String, int> _cart = {};

  bool _isSearching = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _categories = _sortedCategoryRows(widget.initialCategories);
    _menuItems = List<Map<String, dynamic>>.of(widget.initialMenuItems);
    _loading = false;
  }

  String get _outletId => widget.outletData['id'] as String;
  String get _outletName => widget.outletData['name'] as String? ?? 'mejaku';
  String get _tableNumber =>
      widget.tableData['table_number']?.toString() ?? '-';
  String get _tableId => widget.tableData['id'] as String;
  Map<String, dynamic> get _settings =>
      (widget.outletData['settings'] as Map?)?.cast<String, dynamic>() ?? {};
  bool get _allowNotes => _settings['self_order_allow_notes'] != false;
  bool get _requireCustomerName => _settings['self_order_require_name'] == true;

  /// Persentase pajak & service dari setelan outlet (via v_outlets_public).
  ///
  /// WAJIB memakai kunci yang sama dengan yang ditulis owner-panel & dibaca
  /// server (`tax_percent`, `service_charge_percent`). Sebelumnya di sini dibaca
  /// `tax_rate`/`service_rate` — kunci yang tidak pernah ditulis siapa pun —
  /// sehingga selalu jatuh ke 11%/5% hardcoded: pelanggan melihat total yang
  /// berbeda dari yang benar-benar disimpan server. Default 0, bukan angka
  /// tebakan: outlet tanpa pajak tidak boleh dikutip pajak.
  double get _taxPercent {
    final s = widget.outletData['settings'];
    if (s is! Map) return 0;
    if (s['tax_active'] == false) return 0;
    return (s['tax_percent'] as num?)?.toDouble() ?? 0;
  }

  double get _servicePercent {
    final s = widget.outletData['settings'];
    if (s is! Map) return 0;
    return (s['service_charge_percent'] as num?)?.toDouble() ?? 0;
  }

  /// Harga menu sudah memuat pajak → jangan ditambahkan lagi ke total.
  bool get _taxInclusive {
    final s = widget.outletData['settings'];
    return s is Map && s['tax_inclusive'] == true;
  }

  int get _rounding {
    final s = widget.outletData['settings'];
    final value = (s is Map ? (s['rounding'] as num?)?.toInt() : null) ?? 0;
    return {0, 100, 500, 1000}.contains(value) ? value : 0;
  }

  String get _taxCalculation {
    final s = widget.outletData['settings'];
    return s is Map && s['tax_calculation'] is String
        ? s['tax_calculation'] as String
        : 'before_discount';
  }

  Set<String> get _taxOrderTypes {
    final s = widget.outletData['settings'];
    final raw = s is Map ? s['tax_order_types'] : null;
    return raw is List ? raw.map((e) => e.toString()).toSet() : <String>{};
  }

  List<TaxRule> get _taxRules {
    final s = widget.outletData['settings'];
    final raw = s is Map ? s['taxes'] : null;
    if (raw is List && raw.isNotEmpty) {
      final rules = raw.whereType<Map>().map(TaxRule.fromMap).toList();
      if (rules.isNotEmpty) return rules;
    }
    return [
      TaxRule(
        percent: _taxPercent,
        active: _taxPercent > 0,
        inclusive: _taxInclusive,
        calculation: _taxCalculation,
        orderTypes: _taxOrderTypes,
      ),
    ];
  }

  Future<void> _loadMenu() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cats = await _client
          .from('menu_categories')
          .select('id, name, icon, sort_order')
          .eq('outlet_id', _outletId)
          .eq('is_active', true)
          .order('sort_order')
          .order('name');

      final items = await _client
          .from('menu_items')
          .select(
            'id, name, price, image_url, category_id, description, is_featured, sort_order',
          )
          .eq('outlet_id', _outletId)
          .eq('is_available', true)
          .eq('is_active', true)
          .order('is_featured', ascending: false)
          .order('sort_order')
          .order('name');

      setState(() {
        _categories = _sortedCategoryRows(cats);
        _menuItems = List<Map<String, dynamic>>.from(items);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = humanizeError(
          e,
          fallback: 'Gagal memuat. Coba scan ulang QR.',
        );
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredItems {
    var items = _selectedCategoryId == null
        ? _menuItems
        : _menuItems
              .where((i) => i['category_id'] == _selectedCategoryId)
              .toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      items = items
          .where((i) => (i['name'] as String? ?? '').toLowerCase().contains(q))
          .toList();
    }
    items = List<Map<String, dynamic>>.of(items)
      ..sort((a, b) {
        final featured = ((b['is_featured'] as bool? ?? false) ? 1 : 0)
            .compareTo((a['is_featured'] as bool? ?? false) ? 1 : 0);
        if (featured != 0) return featured;
        final order = (a['sort_order'] as int? ?? 0).compareTo(
          b['sort_order'] as int? ?? 0,
        );
        if (order != 0) return order;
        return (a['name'] as String? ?? '').toLowerCase().compareTo(
          (b['name'] as String? ?? '').toLowerCase(),
        );
      });
    return items;
  }

  int get _cartCount => _cart.values.fold(0, (s, q) => s + q);

  void _addToCart(String itemId) =>
      setState(() => _cart[itemId] = (_cart[itemId] ?? 0) + 1);
  void _removeFromCart(String itemId) => setState(() {
    final cur = _cart[itemId] ?? 0;
    if (cur <= 1) {
      _cart.remove(itemId);
    } else {
      _cart[itemId] = cur - 1;
    }
  });

  Future<void> _showOrderList() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OrderListSheet(
        client: _client,
        tableId: _tableId,
        tableNumber: _tableNumber,
      ),
    );
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
  }

  void _showCart() {
    final cartItems = _menuItems
        .where((i) => _cart.containsKey(i['id']))
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _CartScreen(
          tableToken: widget.tableToken,
          outletName: _outletName,
          tableNumber: _tableNumber,
          tableId: _tableId,
          outletId: _outletId,
          cartItems: cartItems,
          quantities: Map.from(_cart),
          taxPercent: _taxPercent,
          servicePercent: _servicePercent,
          taxInclusive: _taxInclusive,
          rounding: _rounding,
          taxCalculation: _taxCalculation,
          taxOrderTypes: _taxOrderTypes,
          taxRules: _taxRules,
          allowNotes: _allowNotes,
          requireCustomerName: _requireCustomerName,
          onOrderSuccess: () {
            setState(() => _cart.clear());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/images/logo.png', fit: BoxFit.cover),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _outletName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppColors.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Online',
                        style: TextStyle(
                          color: AppColors.success,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              'Meja $_tableNumber',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          // Search button
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: AppColors.textPrimary,
            ),
            onPressed: _toggleSearch,
          ),
          // Daftar Order button
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
            child: FilledButton.icon(
              onPressed: _showOrderList,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.receipt_long, size: 18),
              label: const Text('Daftar Order', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: AppColors.error,
                    size: 48,
                  ),
                  const SizedBox(height: 8),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loadMenu,
                    child: const Text('Coba lagi'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Search bar (visible when _isSearching)
                if (_isSearching)
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                      decoration: InputDecoration(
                        hintText: 'Cari menu...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                    ),
                  ),

                // Category filter
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      _CategoryChip(
                        label: 'Semua',
                        selected: _selectedCategoryId == null,
                        onTap: () => setState(() => _selectedCategoryId = null),
                      ),
                      ..._categories.map(
                        (c) => _CategoryChip(
                          label: c['name'] as String,
                          selected: _selectedCategoryId == c['id'],
                          onTap: () => setState(
                            () => _selectedCategoryId = c['id'] as String,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Menu grid
                Expanded(
                  child: _filteredItems.isEmpty
                      ? const Center(
                          child: Text(
                            'Tidak ada menu tersedia',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: 0.8,
                              ),
                          itemCount: _filteredItems.length,
                          itemBuilder: (context, i) {
                            final item = _filteredItems[i];
                            final id = item['id'] as String;
                            final qty = _cart[id] ?? 0;
                            return _MenuItemCard(
                              item: item,
                              quantity: qty,
                              onAdd: () => _addToCart(id),
                              onRemove: qty > 0
                                  ? () => _removeFromCart(id)
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: _cartCount > 0
          ? FloatingActionButton.extended(
              onPressed: _showCart,
              backgroundColor: AppColors.primary,
              icon: const Icon(Icons.shopping_cart),
              label: Text('$_cartCount item'),
            )
          : null,
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback? onRemove;
  const _MenuItemCard({
    required this.item,
    required this.quantity,
    required this.onAdd,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final price = (item['price'] as num).toDouble();
    final imageUrl = item['image_url'] as String?;
    final isFeatured = item['is_featured'] as bool? ?? false;

    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  imageUrl != null && imageUrl.trim().isNotEmpty
                      ? BackendNetworkImage(
                          imageUrl: imageUrl,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          memCacheWidth: 480,
                          placeholderBuilder: (_) => _ImagePlaceholder(),
                          errorBuilder: (_) => _ImagePlaceholder(),
                        )
                      : _ImagePlaceholder(),
                  if (isFeatured)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Semantics(
                        label: 'Menu unggulan',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFC107),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                size: 13,
                                color: Color(0xFF5C4100),
                              ),
                              SizedBox(width: 3),
                              Text(
                                'Unggulan',
                                style: TextStyle(
                                  color: Color(0xFF5C4100),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['name'] as String,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  CurrencyFormatter.format(price),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                quantity == 0
                    ? SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: onAdd,
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size.fromHeight(32),
                          ),
                          child: const Text(
                            '+ Tambah',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                    : Row(
                        children: [
                          IconButton(
                            onPressed: onRemove,
                            icon: const Icon(Icons.remove_circle_outline),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: AppColors.error,
                          ),
                          Expanded(
                            child: Text(
                              '$quantity',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: onAdd,
                            icon: const Icon(Icons.add_circle_outline),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: AppColors.primary,
                          ),
                        ],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.restaurant_menu,
          size: 36,
          color: AppColors.textDisabled,
        ),
      ),
    );
  }
}

// ── Order List Sheet ──────────────────────────────────────────────────────────

class _OrderListSheet extends StatefulWidget {
  final dynamic client;
  final String tableId;
  final String tableNumber;
  const _OrderListSheet({
    required this.client,
    required this.tableId,
    required this.tableNumber,
  });

  @override
  State<_OrderListSheet> createState() => _OrderListSheetState();
}

class _OrderListSheetState extends State<_OrderListSheet> {
  bool _loading = true;
  List<Map<String, dynamic>> _orders = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.client
          .from('orders')
          .select(
            'id, order_number, status, total_amount, created_at, order_items(quantity, unit_price, menu_items(name))',
          )
          .eq('table_id', widget.tableId)
          .not('status', 'in', '("paid","cancelled","void_")')
          .order('created_at', ascending: false);
      setState(() {
        _orders = List<Map<String, dynamic>>.from(data as List);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = humanizeError(
          e,
          fallback: 'Gagal memuat. Coba scan ulang QR.',
        );
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.receipt_long_outlined,
                    color: AppColors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Order Meja ${widget.tableNumber}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _loading ? null : _load,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : _orders.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.receipt_outlined,
                            size: 48,
                            color: AppColors.textDisabled,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Belum ada order aktif',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      controller: ctrl,
                      padding: const EdgeInsets.all(16),
                      itemCount: _orders.length,
                      separatorBuilder: (_, i) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _OrderCard(order: _orders[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  const _OrderCard({required this.order});

  static const _statusLabel = {
    'draft': 'Menunggu konfirmasi',
    'confirmed': 'Dikonfirmasi',
    'preparing': 'Diproses',
    'ready': 'Siap',
    'served': 'Disajikan',
  };

  static const _statusColor = {
    'draft': AppColors.statusDraft,
    'confirmed': AppColors.statusConfirmed,
    'preparing': AppColors.statusPreparing,
    'ready': AppColors.statusReady,
    'served': AppColors.statusServed,
  };

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String? ?? 'draft';
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0;
    final items = (order['order_items'] as List?) ?? [];
    final color = _statusColor[status] ?? AppColors.textSecondary;
    final label = _statusLabel[status] ?? status;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                order['order_number'] as String? ?? '-',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...items.take(3).map((oi) {
              final name =
                  (oi['menu_items'] as Map?)?['name'] as String? ?? '-';
              final qty = oi['quantity'] as int? ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  children: [
                    Text(
                      '$qty×',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (items.length > 3)
              Text(
                '+${items.length - 3} item lainnya',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textDisabled,
                ),
              ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              const Text(
                'Total',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                CurrencyFormatter.format(total),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Cart Screen ───────────────────────────────────────────────────────────────

class _CartScreen extends StatefulWidget {
  final String tableToken;
  final String outletName;
  final String tableNumber;
  final String tableId;
  final String outletId;
  final List<Map<String, dynamic>> cartItems;
  final Map<String, int> quantities;
  final double taxPercent;
  final double servicePercent;
  final bool taxInclusive;
  final int rounding;
  final String taxCalculation;
  final Set<String> taxOrderTypes;
  final List<TaxRule> taxRules;
  final bool allowNotes;
  final bool requireCustomerName;
  final VoidCallback onOrderSuccess;

  const _CartScreen({
    required this.tableToken,
    required this.outletName,
    required this.tableNumber,
    required this.tableId,
    required this.outletId,
    required this.cartItems,
    required this.quantities,
    required this.taxPercent,
    required this.servicePercent,
    required this.taxInclusive,
    required this.rounding,
    required this.taxCalculation,
    required this.taxOrderTypes,
    required this.taxRules,
    required this.allowNotes,
    required this.requireCustomerName,
    required this.onOrderSuccess,
  });

  @override
  State<_CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<_CartScreen> {
  final _client = Supabase.instance.client;
  // Stable for this checkout screen. If the response is lost and the customer
  // taps retry, the server returns the first order instead of creating a copy.
  final String _requestId = const Uuid().v4();
  final _customerNameCtrl = TextEditingController();
  final _memberPhoneCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _submitting = false;

  double get _subtotal {
    double s = 0;
    for (final item in widget.cartItems) {
      final id = item['id'] as String;
      final qty = widget.quantities[id] ?? 0;
      s += (item['price'] as num).toDouble() * qty;
    }
    return s;
  }

  @override
  void dispose() {
    _customerNameCtrl.dispose();
    _memberPhoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Angka yang dilihat pelanggan WAJIB sama dengan yang dihitung & disimpan
  /// server. Server tetap yang berwenang atas total; layar ini hanya mengutip.
  CustomerCartTotals get _totals => CustomerCartTotals.compute(
    subtotal: _subtotal,
    taxPercent: widget.taxPercent,
    servicePercent: widget.servicePercent,
    taxInclusive: widget.taxInclusive,
    rounding: widget.rounding,
    taxCalculation: widget.taxCalculation,
    taxOrderTypes: widget.taxOrderTypes,
    taxRules: widget.taxRules,
  );

  double get _taxAmount => _totals.tax;
  double get _serviceAmount => _totals.service;
  double get _total => _totals.total;

  Future<void> _submitOrder() async {
    if (widget.requireCustomerName && _customerNameCtrl.text.trim().isEmpty) {
      AppToast.error(context, 'Nama pelanggan wajib diisi.');
      return;
    }
    final memberPhone = selfOrderMemberPhoneOrNull(_memberPhoneCtrl.text);
    if (!isValidSelfOrderMemberPhone(memberPhone)) {
      AppToast.error(context, 'Nomor HP member belum valid.');
      return;
    }
    setState(() => _submitting = true);
    try {
      // Satu RPC atomik (order + items) — dulu order lalu item di-loop terpisah,
      // rawan pesanan kosong bila koneksi putus. Nomor urut kini juga harian
      // konsisten (get_next_order_number di server), bukan timestamp lokal.
      final items = widget.cartItems.map((item) {
        final id = item['id'] as String;
        final qty = widget.quantities[id] ?? 0;
        final price = (item['price'] as num).toDouble();
        return {
          'menu_item_id': id,
          'quantity': qty,
          'unit_price': price,
          'subtotal': price * qty,
        };
      }).toList();

      // Total dihitung ulang di server (create_self_order).
      final res = await BackendRequest.withFallback(
        client: _client,
        operation: (client) => client.rpc(
          'create_self_order',
          params: {
            'p_outlet_id': widget.outletId,
            'p_table_id': widget.tableId,
            'p_items': items,
            'p_table_token': widget.tableToken,
            'p_customer_name':
                widget.requireCustomerName ||
                    _customerNameCtrl.text.trim().isNotEmpty
                ? _customerNameCtrl.text.trim()
                : null,
            'p_notes': widget.allowNotes && _notesCtrl.text.isNotEmpty
                ? _notesCtrl.text
                : null,
            // Signature earning-only 188: server mencocokkan nomor tanpa
            // membuka UUID, identitas, atau saldo member ke pelanggan anonim.
            'p_promo_code': null,
            'p_member_phone': memberPhone,
            'p_request_id': _requestId,
          },
        ),
      );
      final orderNumber = (res as Map)['order_number'] as String? ?? '-';

      widget.onOrderSuccess();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => _OrderSuccessScreen(
              orderNumber: orderNumber,
              total: _total,
              onBack: () => Navigator.pop(context),
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        AppToast.error(
          context,
          humanizeError(e, fallback: 'Gagal mengirim pesanan. Coba lagi.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'Pesanan Kamu',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Cart items
          Card(
            elevation: 0,
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ...widget.cartItems.map((item) {
                    final id = item['id'] as String;
                    final qty = widget.quantities[id] ?? 0;
                    final price = (item['price'] as num).toDouble();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text('${item['name']} × $qty')),
                          Text(
                            CurrencyFormatter.format(price * qty),
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    );
                  }),
                  const Divider(height: 20),
                  _SummaryRow('Subtotal', CurrencyFormatter.format(_subtotal)),
                  const SizedBox(height: 4),
                  // Baris pajak/service disembunyikan bila outlet memang tak
                  // memungutnya — jangan tampilkan "Pajak (0%) Rp 0" ke pelanggan.
                  if (_taxAmount > 0)
                    _SummaryRow(
                      widget.taxRules.length > 1
                          ? 'Pajak'
                          : 'Pajak (${widget.taxPercent.toStringAsFixed(0)}%)',
                      CurrencyFormatter.format(_taxAmount),
                      isSecondary: true,
                    ),
                  if (_serviceAmount > 0)
                    _SummaryRow(
                      'Service (${widget.servicePercent.toStringAsFixed(0)}%)',
                      CurrencyFormatter.format(_serviceAmount),
                      isSecondary: true,
                    ),
                  const Divider(height: 20),
                  _SummaryRow(
                    'Total',
                    CurrencyFormatter.format(_total),
                    isBold: true,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.requireCustomerName)
            TextField(
              controller: _customerNameCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Nama pelanggan *',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          if (widget.requireCustomerName) const SizedBox(height: 12),
          TextField(
            controller: _memberPhoneCtrl,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            maxLength: 40,
            decoration: InputDecoration(
              labelText: 'Nomor HP member (opsional)',
              helperText:
                  'Jika terdaftar, poin masuk setelah pembayaran. Penukaran poin melalui kasir.',
              counterText: '',
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.allowNotes)
            TextField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Catatan (opsional)',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submitting ? null : _submitOrder,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Kirim Pesanan', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isBold;
  final bool isSecondary;
  const _SummaryRow(
    this.label,
    this.value, {
    this.isBold = false,
    this.isSecondary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: isSecondary
                  ? AppColors.textSecondary
                  : AppColors.textPrimary,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontSize: isBold ? 16 : 14,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
            color: isBold ? AppColors.primary : AppColors.textPrimary,
            fontSize: isBold ? 18 : 14,
          ),
        ),
      ],
    );
  }
}

// ── Success Screen ────────────────────────────────────────────────────────────

class _OrderSuccessScreen extends StatelessWidget {
  final String orderNumber;
  final double total;
  final VoidCallback onBack;
  const _OrderSuccessScreen({
    required this.orderNumber,
    required this.total,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle,
                  color: AppColors.secondary,
                  size: 48,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Pesanan Berhasil!',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                orderNumber,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                CurrencyFormatter.format(total),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Pesanan kamu sedang diproses!\nSilakan tunggu ya.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: onBack,
                style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
                child: const Text('Pesan Lagi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

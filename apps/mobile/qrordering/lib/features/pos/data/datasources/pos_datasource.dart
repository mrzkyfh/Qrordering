import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../../shared/models/menu_category.dart';
import '../../../../shared/models/menu_item.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/models/cash_movement.dart';
import '../../domain/entities/cart_item.dart';
import '../../domain/catalog_reconciliation.dart';
import '../../../../shared/services/backend_request.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/offline_queue_service.dart';

/// Hasil pembuatan order dari server.
///
/// [totalAmount] wajib dipakai oleh alur split bill. Server menghitung ulang
/// pajak dan biaya layanan dari konfigurasi outlet saat request diterima, jadi
/// total ini dapat berbeda dari cache yang sedang tampil di perangkat.
class CreatedPosOrder {
  final String orderId;
  final String orderNumber;
  final double totalAmount;

  const CreatedPosOrder({
    required this.orderId,
    required this.orderNumber,
    required this.totalAmount,
  });
}

class PosDatasource {
  // Getter, bukan field: pembacaan cache-only (dipakai jalur cetak & diuji
  // tanpa backend) harus bisa jalan tanpa Supabase terinisialisasi.
  SupabaseClient get _client => Supabase.instance.client;
  static const _uuid = Uuid();

  // Box cache menu agar POS tetap bisa menampilkan menu saat offline.
  static const menuCacheBoxName = 'menu_cache_secure_v1';
  static const legacyMenuCacheBoxName = 'menu_cache';
  static const openShiftCacheMaxAge = Duration(hours: 72);
  static const printCacheTtl = Duration(minutes: 10);
  static final Map<String, DateTime> _printCacheWarmAt = {};
  static final Map<String, Future<void>> _printCacheInFlight = {};
  Box? get _cache =>
      Hive.isBoxOpen(menuCacheBoxName) ? Hive.box(menuCacheBoxName) : null;

  /// Ambil setting outlet (pajak & service charge) untuk hitung total.
  /// Di-cache agar tetap tersedia saat offline. Mengembalikan map `settings`.
  Future<Map<String, dynamic>> fetchOutletSettings(String outletId) async {
    final cacheKey = 'settings_$outletId';
    try {
      final data = await _client
          .from('outlets')
          .select('settings')
          .eq('id', outletId)
          .single();
      final settings =
          (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
      _cache?.put(cacheKey, jsonEncode(settings));
      _cache?.put(
        '${cacheKey}_cached_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      return settings;
    } catch (_) {
      final cached = _cache?.get(cacheKey) as String?;
      if (cached != null) {
        return (jsonDecode(cached) as Map).cast<String, dynamic>();
      }
      return {};
    }
  }

  /// Setelan outlet terakhir dari cache menu. Tidak melakukan request jaringan.
  Map<String, dynamic>? cachedOutletSettings(
    String outletId, {
    Duration? maxAge,
  }) {
    final cacheKey = 'settings_$outletId';
    final raw = _cache?.get(cacheKey) as String?;
    if (raw == null) return null;
    if (!_cacheEntryIsFresh('${cacheKey}_cached_at', maxAge)) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Ambil info outlet lengkap untuk cetak struk (nama, alamat, telepon, kota,
  /// settings). Di-cache tiap kali online sehingga struk tetap bisa dicetak
  /// saat offline. Mengembalikan map siap dipakai `OutletReceiptInfo.fromMap`,
  /// atau `null` bila belum pernah ter-cache dan sedang offline.
  Future<Map<String, dynamic>?> fetchOutletReceiptMap(String outletId) async {
    final cacheKey = 'receipt_outlet_$outletId';
    try {
      final data = await _client
          .from('outlets')
          .select('name, address, phone, city, settings')
          .eq('id', outletId)
          .single();
      _cache?.put(cacheKey, jsonEncode(data));
      final settings =
          (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
      final settingsKey = 'settings_$outletId';
      _cache?.put(settingsKey, jsonEncode(settings));
      _cache?.put(
        '${settingsKey}_cached_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      return Map<String, dynamic>.from(data);
    } catch (_) {
      final cached = _cache?.get(cacheKey) as String?;
      if (cached != null) {
        return (jsonDecode(cached) as Map).cast<String, dynamic>();
      }
      return null;
    }
  }

  /// Peta id→nama kategori untuk judul tiket dapur, di-cache agar tersedia
  /// saat offline. Mengembalikan map kosong bila belum ter-cache & offline.
  Future<Map<String, String>> fetchCategoryNames(String outletId) async {
    final cacheKey = 'catnames_$outletId';
    try {
      final rows = await _client
          .from('menu_categories')
          .select('id, name')
          .eq('outlet_id', outletId);
      final map = {
        for (final r in (rows as List))
          (r['id'] as String): (r['name'] as String? ?? ''),
      };
      _cache?.put(cacheKey, jsonEncode(map));
      _cache?.put(
        '${cacheKey}_cached_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      return map;
    } catch (_) {
      final cached = _cache?.get(cacheKey) as String?;
      if (cached != null) {
        return (jsonDecode(cached) as Map).cast<String, String>();
      }
      return {};
    }
  }

  Future<List<MenuCategory>> fetchCategories(String outletId) async {
    final cacheKey = 'cat_$outletId';
    try {
      final data = await _client
          .from('menu_categories')
          .select()
          .eq('outlet_id', outletId)
          .eq('is_active', true)
          .order('sort_order')
          .order('name');
      _cache?.put(cacheKey, jsonEncode(data));
      return _sortedCategories(
        (data as List).map(
          (e) => MenuCategory.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
    } catch (e) {
      // Offline → pakai cache terakhir jika ada.
      final cached = _cache?.get(cacheKey) as String?;
      if (cached == null) rethrow;
      final list = jsonDecode(cached) as List;
      return _sortedCategories(
        list.map(
          (e) => MenuCategory.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
    }
  }

  static List<MenuCategory> _sortedCategories(
    Iterable<MenuCategory> categories,
  ) => List<MenuCategory>.of(categories)..sort(MenuCategory.compare);

  Future<List<MenuItem>> fetchMenuItems(String outletId) async {
    final cacheKey = 'item_$outletId';
    try {
      final data = await _client
          .from('menu_items')
          .select(
            '*, menu_categories(name), menu_item_extras(extra_id, menu_extras(*, menu_extra_options(*)))',
          )
          .eq('outlet_id', outletId)
          .eq('is_active', true)
          .order('is_featured', ascending: false)
          .order('sort_order')
          .order('name');
      // Item yang sedang habis tetap harus tampil di POS dengan badge "Habis".
      // Menyaring is_available di query membuat seluruh grid tampak hilang
      // ketika stok semua item sementara dinonaktifkan.
      _cache?.put(cacheKey, jsonEncode(data));
      return (data as List).map((e) => MenuItem.fromJson(e)).toList();
    } catch (e) {
      final cached = _cache?.get(cacheKey) as String?;
      if (cached == null) rethrow;
      final list = jsonDecode(cached) as List;
      return list
          .map((e) => MenuItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
  }

  /// Selalu membaca katalog remote untuk item di keranjang. Tidak boleh jatuh
  /// ke cache: hasil ini menjadi pagar terakhir sebelum struk dicetak.
  Future<CatalogReconciliation> reconcileCartWithServer(
    String outletId,
    List<CartItem> cart,
  ) async {
    if (cart.isEmpty) {
      return const CatalogReconciliation(
        cart: [],
        catalog: [],
        messages: [],
        blocking: false,
        changed: false,
      );
    }
    final ids = cart.map((item) => item.menuItem.id).toSet().toList();
    final data = await _client
        .from('menu_items')
        .select(
          '*, menu_categories(name), menu_item_extras(extra_id, menu_extras(*, menu_extra_options(*)))',
        )
        .eq('outlet_id', outletId)
        .inFilter('id', ids);
    final catalog = (data as List)
        .map((row) => MenuItem.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    return reconcileCartCatalog(cart, catalog);
  }

  /// Shift terbuka MILIK staf [staffId] (bila ada). Tidak menebak shift orang
  /// lain — untuk staf tanpa shift (owner/admin), atribusi kas tunai ditentukan
  /// di UI (pilih till). Non-fatal: null bila tak ada / gagal.
  Future<String?> _resolveShiftId(String outletId, String? staffId) async {
    if (staffId == null) return null;
    try {
      final own = await _client
          .from('shifts')
          .select('id')
          .eq('outlet_id', outletId)
          .eq('kasir_id', staffId)
          .isFilter('end_time', null)
          .maybeSingle();
      return own?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Shift kasir yang sedang terbuka di outlet (untuk picker "kas masuk ke till
  /// mana" saat owner/admin bayar tunai). Terbaru dulu.
  Future<List<Map<String, dynamic>>> fetchOpenShifts(String outletId) async {
    final verifiedAt = ConnectivityService.instance
        .trustedUtcNow()
        .toIso8601String();
    final data = await _client
        .from('shifts')
        .select(
          'id, kasir_id, start_time, opening_cash, profiles:kasir_id(full_name)',
        )
        .eq('outlet_id', outletId)
        .isFilter('end_time', null)
        .order('start_time', ascending: false);
    final shifts = (data as List).map((r) {
      final m = Map<String, dynamic>.from(r as Map);
      final p = m['profiles'];
      return {
        'id': m['id'],
        'kasir_id': m['kasir_id'],
        'kasir_name': (p is Map ? p['full_name'] : null) ?? 'Kasir',
        'start_time': m['start_time'],
        'opening_cash': m['opening_cash'] ?? 0,
        'verified_at': verifiedAt,
      };
    }).toList();
    _cache?.put('open_shifts_$outletId', jsonEncode(shifts));
    return shifts;
  }

  /// Versi cache-only dari [fetchOpenShifts] — TANPA jaringan.
  ///
  /// Dipakai saat tombol Bayar ditekan: till harus ditentukan sebelum struk
  /// keluar, dan sekali saja menunggu jaringan di titik itu, target cetak 0.1
  /// detik hilang. Cache dihangatkan oleh [warmPrintCaches] saat halaman bayar
  /// dibuka, jadi biasanya sudah terisi begitu kasir selesai mengetik nominal.
  List<Map<String, dynamic>> cachedOpenShifts(
    String outletId, {
    DateTime? now,
  }) {
    final raw = _cache?.get('open_shifts_$outletId') as String?;
    if (raw == null) return const [];
    try {
      final trustedNow = (now ?? ConnectivityService.instance.trustedUtcNow())
          .toUtc();
      return (jsonDecode(raw) as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .where((entry) {
            final shiftId = entry['id'];
            final kasirId = entry['kasir_id'];
            final verifiedAt = DateTime.tryParse(
              entry['verified_at'] as String? ?? '',
            )?.toUtc();
            if (shiftId is! String ||
                shiftId.isEmpty ||
                kasirId is! String ||
                kasirId.isEmpty ||
                verifiedAt == null) {
              return false;
            }
            final age = trustedNow.difference(verifiedAt);
            return !age.isNegative && age <= openShiftCacheMaxAge;
          })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Simpan satu shift aktif ke cache till tanpa menghapus shift aktif milik
  /// kasir lain. Dipanggil setiap kali status shift kasir berhasil dibaca atau
  /// shift baru berhasil dibuka.
  ///
  /// Cache ini bukan sumber kebenaran server. Fungsinya adalah membawa
  /// identitas laci terakhir yang *terbukti terbuka* ke jalur pembayaran saat
  /// koneksi putus, sehingga transaksi tetap dapat diamankan ke antrean lokal.
  Future<void> rememberOpenShift({
    required String outletId,
    required String shiftId,
    required String kasirId,
    String? kasirName,
    DateTime? startTime,
    double? openingCash,
    DateTime? verifiedAt,
  }) async {
    if (outletId.isEmpty || shiftId.isEmpty || kasirId.isEmpty) return;
    final box = _cache;
    if (box == null) return;
    final shifts = cachedOpenShifts(outletId)
        .where(
          (entry) => entry['id'] != shiftId && entry['kasir_id'] != kasirId,
        )
        .toList();
    shifts.insert(0, {
      'id': shiftId,
      'kasir_id': kasirId,
      'kasir_name': kasirName?.trim().isNotEmpty == true
          ? kasirName!.trim()
          : 'Kasir',
      'start_time': (startTime ?? ConnectivityService.instance.trustedUtcNow())
          .toUtc()
          .toIso8601String(),
      'opening_cash': openingCash ?? 0,
      'verified_at':
          (verifiedAt ?? ConnectivityService.instance.trustedUtcNow())
              .toUtc()
              .toIso8601String(),
    });
    await box.put('open_shifts_$outletId', jsonEncode(shifts));
  }

  /// Hapus shift yang sudah dipastikan tidak aktif. Bisa memakai id shift,
  /// id kasir, atau keduanya. Entri kasir lain tetap dipertahankan agar picker
  /// till owner/admin tidak rusak.
  Future<void> forgetOpenShift({
    required String outletId,
    String? shiftId,
    String? kasirId,
  }) async {
    final box = _cache;
    if (box == null || outletId.isEmpty) return;
    final shifts = cachedOpenShifts(outletId).where((entry) {
      final sameShift = shiftId != null && entry['id'] == shiftId;
      final sameKasir = kasirId != null && entry['kasir_id'] == kasirId;
      return !sameShift && !sameKasir;
    }).toList();
    await box.put('open_shifts_$outletId', jsonEncode(shifts));
  }

  /// Shift milik [staffId] sendiri yang sedang terbuka, dari cache — TANPA
  /// jaringan. Padanan cache-only dari [_resolveShiftId] yang dipakai
  /// [createOrder]: dipakai untuk pembayaran NON-tunai, yang tetap harus nempel
  /// ke shift kasir agar laporan per-shift lengkap, tapi tak perlu picker till
  /// (uangnya memang tidak masuk laci fisik).
  String? cachedOwnShiftId(String outletId, String staffId) {
    for (final s in cachedOpenShifts(outletId)) {
      if (s['kasir_id'] == staffId) return s['id'] as String?;
    }
    return null;
  }

  /// Snapshot till yang ikut ditempelkan ke payload transaksi lokal. Informasi
  /// ini membuat kasus cache stale dapat dibuktikan dari perangkat tanpa harus
  /// menebak UUID berdasarkan nama kasir di dashboard.
  Map<String, dynamic>? cachedShiftSnapshot(String outletId, String shiftId) {
    for (final shift in cachedOpenShifts(outletId)) {
      if (shift['id'] == shiftId) return Map<String, dynamic>.from(shift);
    }
    return null;
  }

  /// Cari snapshot till tanpa mengetahui outlet terlebih dahulu. Dipakai saat
  /// penutupan offline karena API lama closeShift hanya membawa shift_id.
  Map<String, dynamic>? cachedShiftSnapshotById(String shiftId) {
    final box = _cache;
    if (box == null || shiftId.isEmpty) return null;
    for (final key in box.keys.whereType<String>()) {
      if (!key.startsWith('open_shifts_')) continue;
      final outletId = key.substring('open_shifts_'.length);
      final snapshot = cachedShiftSnapshot(outletId, shiftId);
      if (snapshot != null) {
        return <String, dynamic>{...snapshot, 'outlet_id': outletId};
      }
    }
    return null;
  }

  List<CashMovement> cachedCashMovements(String shiftId) {
    final raw = _cache?.get('cash_movements_$shiftId') as String?;
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map(
            (entry) => CashMovement.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> cacheCashMovements(
    String shiftId,
    Iterable<CashMovement> movements,
  ) async {
    if (shiftId.isEmpty) return;
    await _cache?.put(
      'cash_movements_$shiftId',
      jsonEncode(movements.map((movement) => movement.toJson()).toList()),
    );
  }

  /// Versi cache-only dari [fetchOutletReceiptMap] — TANPA jaringan.
  Map<String, dynamic>? cachedOutletReceiptMap(String outletId) {
    final raw = _cache?.get('receipt_outlet_$outletId') as String?;
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Gabungkan item tambahan langsung ke order yang header-nya masih berada
  /// di outbox lokal. Tidak membuat jurnal anak karena order induk belum ada
  /// di server; seluruh item akan dibuat atomik saat induk disinkronkan.
  ///
  /// Mengembalikan `null` bila [orderId] bukan order lokal pending, sehingga
  /// pemanggil dapat memakai jurnal append untuk order yang sudah ada di server.
  Future<Map<String, dynamic>?> appendItemsToQueuedOrder({
    required String outletId,
    required String orderId,
    required List<CartItem> items,
    required double taxPercent,
    required bool taxActive,
    required bool taxInclusive,
    required double serviceChargePercent,
    required int roundingIncrement,
  }) async {
    if (items.isEmpty) return null;
    final parent = OfflineQueueService.instance.findByClientOrderId(orderId);
    if (parent == null ||
        parent['outletId'] != outletId ||
        !const {'draft', 'confirmed'}.contains(parent['kind'])) {
      return null;
    }

    final queuedItems = (parent['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    queuedItems.addAll([
      for (final item in items)
        {
          'menuItemId': item.menuItem.id,
          'name': item.menuItem.name,
          'quantity': item.quantity,
          'unitPrice': item.unitPrice,
          'subtotal': item.subtotal,
          'notes': item.notes,
          'extras': [
            for (final extra in item.selectedExtras)
              {
                'menuExtraId': extra.menuExtraId,
                'menuExtraOptionId': extra.menuExtraOptionId,
                'extraName': extra.extraName,
                'optionName': extra.optionName,
                'price': extra.price,
              },
          ],
        },
    ]);
    final subtotal = queuedItems.fold<double>(
      0,
      (sum, item) => sum + ((item['subtotal'] as num?)?.toDouble() ?? 0),
    );
    final tax = !taxActive || taxPercent <= 0
        ? 0.0
        : taxInclusive
        ? (subtotal - subtotal / (1 + taxPercent / 100)).roundToDouble()
        : (subtotal * taxPercent / 100).roundToDouble();
    final service = (subtotal * serviceChargePercent / 100).roundToDouble();
    final discount = (parent['discountAmount'] as num?)?.toDouble() ?? 0;
    final loyalty = (parent['loyaltyDiscount'] as num?)?.toDouble() ?? 0;
    final unrounded =
        (subtotal - discount - loyalty).clamp(0, double.infinity) +
        (taxInclusive ? 0 : tax) +
        service;
    final total = roundingIncrement <= 0
        ? unrounded
        : (unrounded / roundingIncrement).round() *
              roundingIncrement.toDouble();

    return OfflineQueueService.instance.updateByClientOrderId(orderId, {
      'kind': 'confirmed',
      'items': queuedItems,
      'subtotal': subtotal,
      'taxAmount': tax,
      'taxInclusive': taxInclusive,
      'serviceCharge': service,
      'rounding': total - unrounded,
      'total': total,
    });
  }

  /// Terapkan append open-bill ke snapshot Daftar Order secara atomik lokal.
  /// Dengan ini detail order dan Bill langsung memuat item tambahan meski RPC
  /// masih menunggu jaringan. Server tetap menjadi sumber final saat sinkron.
  Future<void> appendItemsToCachedOrder({
    required String outletId,
    required String orderId,
    required List<CartItem> items,
    required double taxPercent,
    required bool taxActive,
    required bool taxInclusive,
    required double serviceChargePercent,
    required int roundingIncrement,
  }) async {
    if (items.isEmpty) return;
    final box = _cache;
    if (box == null) return;
    final key = 'orders_active_$outletId';
    final raw = box.get(key) as String?;
    if (raw == null) return;

    final rows = (jsonDecode(raw) as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final index = rows.indexWhere((row) => row['id'] == orderId);
    if (index < 0) return;
    final order = rows[index];
    final cachedItems = (order['order_items'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    cachedItems.addAll([
      for (final item in items)
        {
          'id': _uuid.v4(),
          'order_id': orderId,
          'menu_item_id': item.menuItem.id,
          'quantity': item.quantity,
          'unit_price': item.unitPrice,
          'subtotal': item.subtotal,
          'notes': item.notes,
          'menu_items': {
            'id': item.menuItem.id,
            'outlet_id': item.menuItem.outletId,
            'category_id': item.menuItem.categoryId,
            'name': item.menuItem.name,
            'price': item.menuItem.price,
            'is_available': item.menuItem.isAvailable,
            'is_active': item.menuItem.isActive,
            'is_featured': item.menuItem.isFeatured,
            'allow_price_override': item.menuItem.allowPriceOverride,
            'sort_order': item.menuItem.sortOrder,
          },
          'order_item_options': [
            for (final extra in item.selectedExtras)
              {
                'extra_name': extra.extraName,
                'option_name': extra.optionName,
                'price': extra.price,
              },
          ],
        },
    ]);

    final subtotal = cachedItems.fold<double>(
      0,
      (sum, item) => sum + ((item['subtotal'] as num?)?.toDouble() ?? 0),
    );
    final tax = !taxActive || taxPercent <= 0
        ? 0.0
        : taxInclusive
        ? (subtotal - subtotal / (1 + taxPercent / 100)).roundToDouble()
        : (subtotal * taxPercent / 100).roundToDouble();
    final service = (subtotal * serviceChargePercent / 100).roundToDouble();
    final discount = (order['discount_amount'] as num?)?.toDouble() ?? 0;
    final loyalty = (order['loyalty_discount'] as num?)?.toDouble() ?? 0;
    final unrounded =
        (subtotal - discount - loyalty).clamp(0, double.infinity) +
        (taxInclusive ? 0 : tax) +
        service;
    final total = roundingIncrement <= 0
        ? unrounded
        : (unrounded / roundingIncrement).round() *
              roundingIncrement.toDouble();

    order
      ..['order_items'] = cachedItems
      ..['subtotal'] = subtotal
      ..['tax_amount'] = tax
      ..['tax_inclusive'] = taxInclusive
      ..['service_charge'] = service
      ..['total_amount'] = total
      ..['rounding'] = total - unrounded
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String()
      ..['_offline_pending_append'] = true;
    rows[index] = order;
    await box.put(key, jsonEncode(rows));
  }

  /// Ganti snapshot item order QR secara lokal agar koreksi kasir tetap dapat
  /// dilakukan saat jaringan putus. Server memvalidasi ulang stok/promo saat
  /// jurnal diputar; penolakan akan masuk status perlu ditinjau.
  Future<void> replaceCachedOrderItems({
    required String outletId,
    required String orderId,
    required List<CartItem> items,
    required String? customerName,
    required double subtotal,
    required double discountAmount,
    required double taxAmount,
    required double serviceCharge,
    required double totalAmount,
  }) async {
    if (items.isEmpty) return;
    final box = _cache;
    if (box == null) return;
    final key = 'orders_active_$outletId';
    final raw = box.get(key) as String?;
    if (raw == null) return;
    final rows = (jsonDecode(raw) as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final index = rows.indexWhere((row) => row['id'] == orderId);
    if (index < 0) return;
    final order = rows[index];
    order['customer_name'] = customerName;
    order['subtotal'] = subtotal;
    order['discount_amount'] = discountAmount;
    order['tax_amount'] = taxAmount;
    order['service_charge'] = serviceCharge;
    order['total_amount'] = totalAmount;
    order['updated_at'] = DateTime.now().toUtc().toIso8601String();
    order['order_items'] = [
      for (final item in items)
        {
          'id': _uuid.v4(),
          'order_id': orderId,
          'menu_item_id': item.menuItem.id,
          'quantity': item.quantity,
          'unit_price': item.unitPrice,
          'subtotal': item.subtotal,
          'notes': item.notes,
          'menu_items': {
            'id': item.menuItem.id,
            'outlet_id': item.menuItem.outletId,
            'category_id': item.menuItem.categoryId,
            'name': item.menuItem.name,
            'price': item.menuItem.price,
            'is_available': item.menuItem.isAvailable,
            'is_active': item.menuItem.isActive,
            'is_featured': item.menuItem.isFeatured,
            'allow_price_override': item.menuItem.allowPriceOverride,
            'sort_order': item.menuItem.sortOrder,
          },
          'order_item_options': [
            for (final extra in item.selectedExtras)
              {
                'extra_name': extra.extraName,
                'option_name': extra.optionName,
                'price': extra.price,
              },
          ],
        },
    ];
    rows[index] = order;
    await box.put(key, jsonEncode(rows));
  }

  /// Versi cache-only dari [fetchCategoryNames] — TANPA jaringan.
  Map<String, String> cachedCategoryNames(String outletId, {Duration? maxAge}) {
    final cacheKey = 'catnames_$outletId';
    final raw = _cache?.get(cacheKey) as String?;
    if (raw != null && _cacheEntryIsFresh('${cacheKey}_cached_at', maxAge)) {
      try {
        return (jsonDecode(raw) as Map).cast<String, String>();
      } catch (_) {
        // Coba cache kategori lengkap di bawah.
      }
    }
    final categories = _cache?.get('cat_$outletId') as String?;
    if (categories != null && maxAge == null) {
      try {
        final rows = jsonDecode(categories) as List;
        return {
          for (final row in rows.whereType<Map>())
            if (row['id'] is String)
              row['id'] as String: row['name']?.toString() ?? '',
        };
      } catch (_) {
        // Cache lama/rusak dianggap kosong.
      }
    }
    return const {};
  }

  bool _cacheEntryIsFresh(String timestampKey, Duration? maxAge) {
    if (maxAge == null) return true;
    final raw = _cache?.get(timestampKey) as String?;
    final cachedAt = raw == null ? null : DateTime.tryParse(raw)?.toUtc();
    if (cachedAt == null) return false;
    final age = DateTime.now().toUtc().difference(cachedAt);
    return !age.isNegative && age <= maxAge;
  }

  /// Hangatkan semua cache yang dibutuhkan untuk mencetak tanpa jaringan.
  ///
  /// Dipanggil saat halaman bayar DIBUKA (bukan saat Bayar ditekan) supaya
  /// fetch-nya berjalan selagi kasir memilih metode & mengetik nominal. Aman
  /// gagal: tiap fetch sudah punya fallback cache sendiri, dan bila memang belum
  /// pernah ter-cache, jalur cetak yang memberi tahu kasir.
  Future<void> warmPrintCaches(String outletId) async {
    if (outletId.isEmpty) return;
    final warmedAt = _printCacheWarmAt[outletId];
    final hasRequiredCache =
        cachedOutletReceiptMap(outletId) != null &&
        cachedCategoryNames(outletId).isNotEmpty;
    if (hasRequiredCache &&
        warmedAt != null &&
        DateTime.now().difference(warmedAt) < printCacheTtl) {
      return;
    }
    final running = _printCacheInFlight[outletId];
    if (running != null) return running;
    final future =
        Future.wait([
          fetchOutletReceiptMap(outletId),
          fetchCategoryNames(outletId),
          fetchOpenShifts(outletId).catchError((_) => <Map<String, dynamic>>[]),
        ]).then<void>((_) {
          _printCacheWarmAt[outletId] = DateTime.now();
        });
    _printCacheInFlight[outletId] = future;
    try {
      await future;
    } finally {
      if (identical(_printCacheInFlight[outletId], future)) {
        _printCacheInFlight.remove(outletId);
      }
    }
  }

  Future<String> createOrder({
    required String outletId,
    required List<CartItem> cart,
    required OrderType orderType,
    String? tableId,
    double discountAmount = 0,
    double taxAmount = 0,
    double serviceCharge = 0,
    bool taxInclusive = false,
    int rounding = 0,
    required String createdBy,
    String? customerName,
    String? loyaltyMemberId,
    double loyaltyDiscount = 0,
    int redeemedPoints = 0,
    String? promoId,
    String? voucherId,
    String status = 'confirmed',
    String?
    shiftIdOverride, // dipilih di UI (mis. owner bayar tunai → till mana)
    String? clientOrderId,
  }) async {
    final result = await createOrderWithServerTotal(
      outletId: outletId,
      cart: cart,
      orderType: orderType,
      tableId: tableId,
      discountAmount: discountAmount,
      taxAmount: taxAmount,
      serviceCharge: serviceCharge,
      taxInclusive: taxInclusive,
      rounding: rounding,
      createdBy: createdBy,
      customerName: customerName,
      loyaltyMemberId: loyaltyMemberId,
      loyaltyDiscount: loyaltyDiscount,
      redeemedPoints: redeemedPoints,
      promoId: promoId,
      voucherId: voucherId,
      status: status,
      shiftIdOverride: shiftIdOverride,
      clientOrderId: clientOrderId,
    );
    return result.orderId;
  }

  /// Membuat order dan mengembalikan total resmi hasil kalkulasi server.
  ///
  /// Jalur pembayaran biasa tetap dapat memakai [createOrder] bila hanya
  /// membutuhkan id. Split bill harus memakai method ini agar pembagian uang
  /// tidak didasarkan pada total cache yang mungkin sudah tertinggal.
  Future<CreatedPosOrder> createOrderWithServerTotal({
    required String outletId,
    required List<CartItem> cart,
    required OrderType orderType,
    String? tableId,
    double discountAmount = 0,
    double taxAmount = 0,
    double serviceCharge = 0,
    bool taxInclusive = false,
    int rounding = 0,
    required String createdBy,
    String? customerName,
    String? loyaltyMemberId,
    double loyaltyDiscount = 0,
    int redeemedPoints = 0,
    String? promoId,
    String? voucherId,
    String status = 'confirmed',
    String? shiftIdOverride,
    String? clientOrderId,
  }) async {
    // Shift untuk order: pakai pilihan UI bila ada (owner/admin pilih till saat
    // bayar tunai), else shift milik staf sendiri (kasir), else null.
    final shiftId =
        shiftIdOverride ?? await _resolveShiftId(outletId, createdBy);

    final result = await _withTransportFallback(
      (client) => client.rpc(
        'create_pos_order',
        params: {
          'p_outlet_id': outletId,
          'p_order_type': orderType.value,
          'p_status': status,
          'p_items': cart
              .map(
                (item) => {
                  'menu_item_id': item.menuItem.id,
                  'quantity': item.quantity,
                  'unit_price': item.unitPrice,
                  'notes': item.notes,
                  'extras': item.selectedExtras
                      .map(
                        (extra) => {
                          'menu_extra_option_id': extra.menuExtraOptionId,
                        },
                      )
                      .toList(),
                },
              )
              .toList(),
          'p_created_by': createdBy,
          'p_discount_amount': discountAmount,
          'p_tax_amount': taxAmount,
          'p_service_charge': serviceCharge,
          'p_tax_inclusive': taxInclusive,
          'p_rounding': rounding,
          'p_table_id': tableId,
          'p_shift_id': shiftId,
          'p_customer_name': customerName,
          'p_loyalty_member_id': loyaltyMemberId,
          'p_loyalty_discount': loyaltyDiscount,
          'p_redeemed_points': redeemedPoints,
          'p_promo_id': promoId,
          'p_voucher_id': voucherId,
          // Split bill/draft dapat menerima respons yang hilang setelah order
          // dibuat. Hanya kirim ID bila pemanggil memiliki ID stabil; jalur
          // lama tetap membiarkan server menghasilkan UUID sendiri.
          ...?clientOrderId == null
              ? null
              : <String, dynamic>{'p_order_id': clientOrderId},
        },
      ),
    );
    final data = (result as Map).cast<String, dynamic>();
    return CreatedPosOrder(
      orderId: data['order_id'] as String,
      orderNumber: (data['order_number'] as String?) ?? '',
      totalAmount: (data['total_amount'] as num).toDouble(),
    );
  }

  /// Tambah item ke order yang SUDAH ADA (open bill, ala Majoo). Menyisipkan
  /// order_items + extra baru lalu menghitung ulang total order. Mengembalikan
  /// daftar OrderItem yang baru ditambahkan (untuk cetak tiket dapur item baru).
  Future<List<OrderItem>> addItemsToExistingOrder({
    required String orderId,
    required List<CartItem> newItems,
    required double taxPercent,
    required bool taxActive,
    required double serviceChargePercent,
    String? requestId,
  }) async {
    if (newItems.isEmpty) return const [];

    return addItemsToExistingOrderAtomic(
      orderId: orderId,
      newItems: newItems,
      taxPercent: taxPercent,
      taxActive: taxActive,
      serviceChargePercent: serviceChargePercent,
      requestId: requestId,
    );

    /* Legacy non-atomic implementation retained below as migration context;
       it is unreachable and must not be used.

    // 1. Sisipkan item baru.
    final inserted = await _client
        .from('order_items')
        .insert(
          newItems
              .map(
                (item) => {
                  'order_id': orderId,
                  'menu_item_id': item.menuItem.id,
                  'quantity': item.quantity,
                  'unit_price': item.unitPrice,
                  'subtotal': item.subtotal,
                  'notes': item.notes,
                },
              )
              .toList(),
        )
        .select('id');

    // 2. Sisipkan extra untuk item baru.
    final optionRows = <Map<String, dynamic>>[];
    for (var i = 0; i < newItems.length; i++) {
      final cartItem = newItems[i];
      if (cartItem.selectedExtras.isEmpty) continue;
      final orderItemId = (inserted as List)[i]['id'] as String;
      for (final extra in cartItem.selectedExtras) {
        optionRows.add({
          'order_item_id': orderItemId,
          'menu_extra_id': extra.menuExtraId,
          'menu_extra_option_id': extra.menuExtraOptionId,
          'extra_name': extra.extraName,
          'option_name': extra.optionName,
          'price': extra.price,
        });
      }
    }
    if (optionRows.isNotEmpty) {
      await _client.from('order_item_options').insert(optionRows);
    }

    // 3. Hitung ulang total order dari SEMUA item.
    final allItems = await _client
        .from('order_items')
        .select('subtotal')
        .eq('order_id', orderId);
    final subtotal = (allItems as List).fold<double>(
      0,
      (s, r) => s + ((r['subtotal'] as num?)?.toDouble() ?? 0),
    );

    // Perlakuan pajak diambil dari SNAPSHOT order (116), bukan setelan outlet
    // saat ini: order yang dibuka kemarin harus tetap memakai perlakuan saat ia
    // dibuat, walau owner sudah mengubah setelannya sejak itu.
    final head = await _client
        .from('orders')
        .select('tax_inclusive')
        .eq('id', orderId)
        .single();
    final taxInclusive = (head['tax_inclusive'] as bool?) ?? false;

    // Harga yang sudah memuat pajak tidak boleh ditambahi lagi. Tanpa ini,
    // menambah item ke open bill menagih pajak dobel — bug yang sama seperti di
    // PosState, hanya beda jalur.
    final tax = !taxActive || taxPercent <= 0
        ? 0.0
        : taxInclusive
        ? (subtotal - subtotal / (1 + taxPercent / 100)).roundToDouble()
        : (subtotal * taxPercent / 100).roundToDouble();
    final service = (subtotal * serviceChargePercent / 100).roundToDouble();

    // total_amount sengaja TIDAK dikirim: trigger enforce_order_total (116)
    // menurunkannya dari komponen di server. Server yang berwenang atas total.
    await _client
        .from('orders')
        .update({
          'subtotal': subtotal,
          'tax_amount': tax,
          'service_charge': service,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', orderId);

    // 3b. Potong stok untuk item baru saja. Trigger stok order hanya jalan saat
    // status berubah, jadi item open-bill harus dipotong eksplisit di sini
    // (kalau tidak, stok bahan baku bocor / tak berkurang).
    final newItemIds = (inserted as List)
        .map((r) => r['id'] as String)
        .toList();
    if (newItemIds.isNotEmpty) {
      await _client.rpc(
        'deduct_stock_for_items',
        params: {'p_order_id': orderId, 'p_item_ids': newItemIds},
      );
    }

    // 4. Bangun OrderItem hasil insert (untuk cetak tiket item baru).
    final result = <OrderItem>[];
    for (var i = 0; i < newItems.length; i++) {
      final c = newItems[i];
      result.add(
        OrderItem(
          id: (inserted as List)[i]['id'] as String,
          orderId: orderId,
          menuItemId: c.menuItem.id,
          quantity: c.quantity,
          unitPrice: c.unitPrice,
          subtotal: c.subtotal,
          notes: c.notes,
          menuItem: c.menuItem,
        ),
      );
    }
    return result;
    */
  }

  /// Jalur atomik untuk open bill. Dipakai oleh POS setelah migration 141;
  /// method lama dipertahankan sementara untuk kompatibilitas pemanggil lama.
  Future<List<OrderItem>> addItemsToExistingOrderAtomic({
    required String orderId,
    required List<CartItem> newItems,
    required double taxPercent,
    required bool taxActive,
    required double serviceChargePercent,
    String? requestId,
  }) async {
    if (newItems.isEmpty) return const [];
    final operationId = requestId ?? const Uuid().v4();
    final raw = await _withTransportFallback(
      (client) => client.rpc(
        'append_order_items',
        params: {
          'p_order_id': orderId,
          'p_items': newItems
              .map(
                (item) => {
                  'menu_item_id': item.menuItem.id,
                  'quantity': item.quantity,
                  'unit_price': item.unitPrice,
                  'notes': item.notes,
                  'extras': item.selectedExtras
                      .map(
                        (extra) => {
                          'menu_extra_option_id': extra.menuExtraOptionId,
                        },
                      )
                      .toList(),
                },
              )
              .toList(),
          'p_tax_percent': taxPercent,
          'p_tax_active': taxActive,
          'p_service_charge_percent': serviceChargePercent,
          'p_request_id': operationId,
        },
      ),
    );
    final inserted = (raw as List).cast<Map<String, dynamic>>();
    return [
      for (var i = 0; i < newItems.length; i++)
        OrderItem(
          id: inserted[i]['id'] as String,
          orderId: orderId,
          menuItemId: newItems[i].menuItem.id,
          quantity: newItems[i].quantity,
          unitPrice: newItems[i].unitPrice,
          subtotal: newItems[i].subtotal,
          notes: newItems[i].notes,
          menuItem: newItems[i].menuItem,
          options: [
            for (final extra in newItems[i].selectedExtras)
              OrderItemOption(
                extraName: extra.extraName,
                optionName: extra.optionName,
                price: extra.price,
              ),
          ],
        ),
    ];
  }

  /// Ganti seluruh item pesanan online yang masih menunggu proses dapur.
  ///
  /// Server mengunci order, memulihkan stok item lama, memasukkan item baru,
  /// menghitung ulang nominal, memotong stok baru, dan menulis audit dalam satu
  /// transaksi. Bila salah satu langkah gagal, isi order lama tetap utuh.
  Future<void> replaceOnlineOrderItems({
    required String orderId,
    required List<CartItem> items,
    String? customerName,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('Pesanan harus memiliki minimal satu item');
    }
    await _withTransportFallback(
      (client) => client.rpc(
        'replace_online_order_items',
        params: {
          'p_order_id': orderId,
          'p_items': items
              .map(
                (item) => {
                  'menu_item_id': item.menuItem.id,
                  'quantity': item.quantity,
                  'unit_price': item.unitPrice,
                  'notes': item.notes,
                  'extras': item.selectedExtras
                      .map(
                        (extra) => {
                          'menu_extra_option_id': extra.menuExtraOptionId,
                        },
                      )
                      .toList(),
                },
              )
              .toList(),
          'p_customer_name': customerName?.trim(),
        },
      ),
    );
  }

  /// Bahan baku yang BARU menyentuh batas minimum akibat order ini (untuk alert
  /// proaktif). Best-effort — kembalikan kosong bila gagal (jangan ganggu alur).
  Future<List<String>> lowStockAfterOrder(String orderId) async {
    try {
      final rows = await _client.rpc(
        'low_stock_after_order',
        params: {'p_order_id': orderId},
      );
      return (rows as List)
          .map((r) => (r['name'] as String?) ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> validatePromo({
    required String code,
    required String outletId,
    required double subtotal,
  }) async {
    final result = await _client.rpc(
      'validate_promo_code',
      params: {'p_code': code, 'p_outlet_id': outletId, 'p_subtotal': subtotal},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>?> findLoyaltyMember({
    required String phone,
    required String outletId,
  }) async {
    final result = await _client.rpc(
      'find_loyalty_member_by_phone',
      params: {'p_phone': phone, 'p_outlet_id': outletId},
    );
    if (result == null) return null;
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> validateLoyaltyRedeem({
    required String memberId,
    required int points,
    required double subtotal,
    double promoDiscount = 0,
  }) async {
    final result = await _client.rpc(
      'validate_loyalty_redeem',
      params: {
        'p_member_id': memberId,
        'p_points': points,
        'p_subtotal': subtotal,
        'p_promo_discount': promoDiscount,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<double> redeemLoyaltyPoints({
    required String orderId,
    required String memberId,
    required int points,
  }) async {
    final result = await _client.rpc(
      'redeem_loyalty_points',
      params: {
        'p_order_id': orderId,
        'p_member_id': memberId,
        'p_points': points,
      },
    );
    return (result as num?)?.toDouble() ?? 0;
  }

  Future<int> awardLoyaltyPoints({
    required String orderId,
    required String memberId,
  }) async {
    final result = await _client.rpc(
      'award_loyalty_points',
      params: {'p_order_id': orderId, 'p_member_id': memberId},
    );
    return (result as num?)?.toInt() ?? 0;
  }

  Future<void> applyPromoUsage({
    required String promoId,
    String? voucherId,
    required String orderId,
  }) async {
    await _client.rpc(
      'apply_promo_usage',
      params: {
        'p_promo_id': promoId,
        'p_voucher_id': voucherId,
        'p_order_id': orderId,
      },
    );
  }

  Future<void> processPayment({
    required String orderId,
    required String outletId,
    required PaymentMethod method,
    required double amount,
    String? referenceNumber,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? _uuid.v4();
    final cashierId = _client.auth.currentUser?.id;
    final shiftId = await _resolveShiftId(outletId, cashierId);
    if (shiftId == null) {
      throw StateError(
        'Pembayaran wajib dihubungkan ke shift kasir yang sedang aktif',
      );
    }

    // Konteks shift dan payment ditulis dalam satu transaksi server.
    await _withTransportFallback(
      (client) => client.rpc(
        'record_pos_payment_with_context',
        params: {
          'p_order_id': orderId,
          'p_outlet_id': outletId,
          'p_shift_id': shiftId,
          'p_force_order_shift': method == PaymentMethod.cash,
          'p_method': method.value,
          'p_amount': amount,
          'p_reference_number': referenceNumber,
          'p_idempotency_key': key,
          'p_finalize': true,
        },
      ),
    );
  }

  /// Replay sebuah transaksi yang dibuat offline ke server.
  ///
  /// Idempoten PER LANGKAH, bukan per order: push sebelumnya bisa gagal di
  /// tengah (header masuk, items/pembayaran belum). Kalau berhenti hanya
  /// karena header sudah ada, items & pembayaran hilang permanen — jadi tiap
  /// langkah dicek sendiri dan hanya dikerjakan bila belum ada.
  Future<void> pushOfflineOrder(Map<String, dynamic> p) async {
    return _pushOfflineOrderAtomic(p);
  }

  Future<void> _pushOfflineOrderAtomic(Map<String, dynamic> p) async {
    final orderId = p['clientOrderId'] as String;
    final outletId = p['outletId'] as String;
    final isDraft = p['kind'] == 'draft';
    final isPaid = p['kind'] == 'paid';
    final replacesOrderId = p['replacesOrderId'] as String?;

    final items = (p['items'] as List).cast<Map>();
    await _withTransportFallback(
      (client) => client.rpc(
        'create_pos_order',
        params: {
          'p_outlet_id': outletId,
          'p_order_type': p['orderType'],
          'p_status': isDraft ? 'draft' : 'confirmed',
          'p_items': items
              .map(
                (it) => {
                  'menu_item_id': it['menuItemId'],
                  'quantity': it['quantity'],
                  'unit_price': it['unitPrice'],
                  'notes': it['notes'],
                  'extras': ((it['extras'] as List?) ?? const [])
                      .map(
                        (e) => {
                          'menu_extra_option_id':
                              (e as Map)['menuExtraOptionId'],
                        },
                      )
                      .toList(),
                },
              )
              .toList(),
          'p_created_by': p['createdBy'],
          'p_discount_amount': p['discountAmount'] ?? 0,
          'p_tax_amount': p['taxAmount'] ?? 0,
          'p_service_charge': p['serviceCharge'] ?? 0,
          'p_tax_inclusive': p['taxInclusive'] ?? false,
          'p_rounding': p['rounding'] ?? 0,
          'p_table_id': p['tableId'],
          'p_shift_id': p['shiftId'],
          'p_customer_name': p['customerName'],
          'p_loyalty_member_id': p['loyaltyMemberId'],
          'p_loyalty_discount': p['loyaltyDiscount'] ?? 0,
          'p_redeemed_points': p['redeemedPoints'] ?? 0,
          'p_promo_id': p['promoId'],
          'p_voucher_id': p['voucherId'],
          'p_order_id': orderId,
          'p_created_at': p['createdAt'],
          'p_local_receipt_no': p['localReceiptNo'],
        },
      ),
    );

    // Tiket confirmed dapat sudah keluar ketika perangkat offline. Setelah
    // header order tersedia di server, akui hasil lokal melalui lease yang
    // sama dengan autoprint QR agar pembayaran berikutnya tidak mencetak ulang
    // seluruh item. Bila perangkat lain sudah mengambil klaim, ia tetap menjadi
    // pemilik sah dan replay order boleh dilanjutkan.
    if (p['localKitchenPrinted'] == true &&
        p['kitchenPrintDeviceId'] is String &&
        (p['kitchenPrintDeviceId'] as String).isNotEmpty) {
      final deviceId = p['kitchenPrintDeviceId'] as String;
      final claimed = await _withTransportFallback(
        (client) => client.rpc(
          'claim_kitchen_print',
          params: {'p_order_id': orderId, 'p_device_id': deviceId},
        ),
      );
      if (claimed == true) {
        final completed = await _withTransportFallback(
          (client) => client.rpc(
            'complete_kitchen_print',
            params: {'p_order_id': orderId, 'p_device_id': deviceId},
          ),
        );
        if (completed != true) {
          throw StateError('Konfirmasi tiket dapur offline belum tersimpan');
        }
      }
    }

    if (!isPaid) {
      await _deleteReplacedDraft(replacesOrderId, outletId);
      return;
    }

    final rawPayments = (p['payments'] as List?)
        ?.whereType<Map>()
        .map((payment) => Map<String, dynamic>.from(payment))
        .toList();
    Object? paymentResult;
    if (rawPayments != null && rawPayments.isNotEmpty) {
      for (final payment in rawPayments) {
        await _withTransportFallback(
          (client) => client.rpc(
            'record_pos_payment_with_context',
            params: {
              'p_order_id': orderId,
              'p_outlet_id': outletId,
              'p_shift_id': p['shiftId'],
              'p_force_order_shift': payment['method'] == 'cash',
              'p_method': payment['method'],
              'p_amount': payment['amount'],
              'p_reference_number': null,
              'p_idempotency_key': payment['idempotencyKey'],
              'p_finalize': false,
              'p_paid_at': payment['paidAt'] ?? p['paidAt'] ?? p['createdAt'],
            },
          ),
        );
      }
      paymentResult = await _withTransportFallback(
        (client) => client.rpc(
          'finalize_split_payment',
          params: {'p_order_id': orderId},
        ),
      );
    } else {
      paymentResult = await _withTransportFallback(
        (client) => client.rpc(
          'record_pos_payment_with_context',
          params: {
            'p_order_id': orderId,
            'p_outlet_id': outletId,
            'p_shift_id': p['shiftId'],
            'p_force_order_shift': p['paymentMethod'] == 'cash',
            'p_method': p['paymentMethod'],
            'p_amount': p['amount'],
            'p_reference_number': null,
            'p_idempotency_key': p['idempotencyKey'],
            'p_finalize': true,
            'p_paid_at': p['paidAt'] ?? p['createdAt'],
          },
        ),
      );
    }
    final payment = paymentResult is Map
        ? paymentResult.cast<String, dynamic>()
        : const <String, dynamic>{};
    if (payment['status'] != 'paid') {
      // Jangan hapus antrean bila server menerima payment tetapi total resmi
      // telah berubah (mis. setting pajak/katalog berubah selama offline).
      // Idempotency key membuat retry aman; entri dipertahankan untuk
      // rekonsiliasi alih-alih transaksi terlihat sukses lalu menghilang.
      throw PostgrestException(
        message:
            'Pembayaran offline belum melunasi total resmi server '
            '(terbayar ${payment['paid_total'] ?? 0}, '
            'total ${payment['order_total'] ?? 0})',
        code: '22023',
        details: payment,
      );
    }

    final memberId = p['loyaltyMemberId'] as String?;
    if (memberId != null) {
      try {
        await awardLoyaltyPoints(orderId: orderId, memberId: memberId);
      } catch (_) {
        // Earn bersifat idempoten dan boleh diulang pada retry berikutnya.
      }
    }
    await _deleteReplacedDraft(replacesOrderId, outletId);
    return;

    /* Legacy per-step replay kept only as historical context.
    // 1. Header order (skip bila sudah tersinkron sebelumnya).
    final existing = await _client
        .from('orders')
        .select('id')
        .eq('id', orderId)
        .maybeSingle();
    if (existing == null) {
      final orderNumber =
          await _client.rpc(
                'get_next_pos_order_number',
                params: {'p_outlet_id': outletId},
              )
              as String;

      // Draf → status 'draft'; transaksi terbayar → 'confirmed' dulu (mirror online).
      await _client.from('orders').insert({
        'id': orderId,
        'outlet_id': outletId,
        'order_number': orderNumber,
        'order_type': p['orderType'],
        'table_id': p['tableId'],
        'customer_name': p['customerName'],
        'status': isDraft ? 'draft' : 'confirmed',
        'subtotal': p['subtotal'],
        'discount_amount': p['discountAmount'] ?? 0,
        'tax_amount': p['taxAmount'] ?? 0,
        'service_charge': p['serviceCharge'] ?? 0,
        // Snapshot perlakuan pajak SAAT transaksi terjadi — bukan setelan saat
        // sync. Order offline bisa tersinkron berhari-hari kemudian, setelah
        // owner mengubah pajak; tanpa snapshot ini, totalnya akan dihitung ulang
        // dengan tarif baru padahal pelanggan sudah membayar tarif lama.
        'tax_inclusive': p['taxInclusive'] ?? false,
        'rounding': p['rounding'] ?? 0,
        // total_amount diturunkan server dari komponen (trigger 116).
        'stock_deducted': false,
        'created_by': p['createdBy'],
        'created_at': p['createdAt'], // pertahankan waktu transaksi asli
        // Till & loyalty ikut direplay persis seperti createOrder. Tanpa ini kas
        // tunai tak nempel ke laci mana pun (rekonsiliasi kasir meleset) dan
        // diskon poin tercatat di total tapi tak pernah dipotong dari member.
        //
        // shift_id sengaja dipakai apa adanya dari payload — itu till yang
        // terbuka SAAT transaksi, yang memang atribusi yang benar secara
        // historis, walau shift tersebut sudah ditutup saat sync berjalan.
        'shift_id': p['shiftId'],
        'loyalty_member_id': p['loyaltyMemberId'],
        'loyalty_discount': p['loyaltyDiscount'] ?? 0,
        'redeemed_points': p['redeemedPoints'] ?? 0,
        // Jembatan struk fisik → order server (migration 112).
        'local_receipt_no': p['localReceiptNo'],
      });
    }

    // 2. Order items — batch insert bersifat atomik (semua/tidak sama sekali),
    //    jadi cukup cek keberadaan satu baris.
    final items = (p['items'] as List).cast<Map>();
    final existingItems = await _client
        .from('order_items')
        .select('id')
        .eq('order_id', orderId)
        .limit(1);
    if ((existingItems as List).isEmpty && items.isNotEmpty) {
      final inserted = await _client
          .from('order_items')
          .insert(
            items
                .map(
                  (it) => {
                    'order_id': orderId,
                    'menu_item_id': it['menuItemId'],
                    'quantity': it['quantity'],
                    'unit_price': it['unitPrice'],
                    'subtotal': it['subtotal'],
                    'notes': it['notes'],
                  },
                )
                .toList(),
          )
          .select('id');

      // Order item options (extras).
      final optionRows = <Map<String, dynamic>>[];
      for (var i = 0; i < items.length; i++) {
        final extras = (items[i]['extras'] as List?) ?? const [];
        if (extras.isEmpty) continue;
        final orderItemId = (inserted as List)[i]['id'] as String;
        for (final e in extras.cast<Map>()) {
          optionRows.add({
            'order_item_id': orderItemId,
            'menu_extra_id': e['menuExtraId'],
            'menu_extra_option_id': e['menuExtraOptionId'],
            'extra_name': e['extraName'],
            'option_name': e['optionName'],
            'price': e['price'],
          });
        }
      }
      if (optionRows.isNotEmpty) {
        await _client.from('order_item_options').insert(optionRows);
      }
    }

    // Draf cukup sampai sini (belum dibayar). Bila ini hasil edit draf,
    // bersihkan draf lama hanya setelah header + item pengganti berhasil.
    if (isDraft) {
      await _deleteReplacedDraft(replacesOrderId, outletId);
      return;
    }

    // Pembayaran dan keputusan lunas dijaga server. Ini juga membuat replay
    // offline aman untuk owner yang bekerja lintas outlet.
    await _client.rpc(
      'record_pos_payment',
      params: {
        'p_order_id': orderId,
        'p_outlet_id': outletId,
        'p_method': p['paymentMethod'],
        'p_amount': p['amount'],
        'p_reference_number': null,
        'p_idempotency_key': p['idempotencyKey'],
        'p_finalize': true,
        'p_paid_at': p['paidAt'] ?? p['createdAt'],
      },
    );

    // Promo & loyalty — mirror _afterOrderSettled di jalur online. Dijalankan
    // SETELAH status 'paid' karena award_loyalty_points hanya mengakui order
    // yang sudah lunas.
    //
    // Ketiga RPC idempoten per order_id (041/043/076), jadi aman diulang bila
    // push sebelumnya berhenti di tengah — replay tidak menggandakan poin.
    // Non-fatal seperti di jalur online: transaksi & uangnya tetap sah walau
    // poin gagal tercatat, dan melempar di sini hanya akan membuang seluruh
    // order ke dead-letter padahal order-nya sendiri sudah sukses tersimpan.
    final promoId = p['promoId'] as String?;
    if (promoId != null) {
      try {
        await applyPromoUsage(
          promoId: promoId,
          voucherId: p['voucherId'] as String?,
          orderId: orderId,
        );
      } catch (_) {
        // non-fatal
      }
    }
    final memberId = p['loyaltyMemberId'] as String?;
    if (memberId != null) {
      final points = (p['redeemedPoints'] as num?)?.toInt() ?? 0;
      if (points > 0) {
        try {
          await redeemLoyaltyPoints(
            orderId: orderId,
            memberId: memberId,
            points: points,
          );
        } catch (_) {
          // non-fatal
        }
      }
      try {
        await awardLoyaltyPoints(orderId: orderId, memberId: memberId);
      } catch (_) {
        // non-fatal
      }
    }

    // Untuk pembayaran offline hasil edit draf, order lama tetap dipelihara
    // sampai seluruh order baru dan pembayarannya sukses tersinkron.
    await _deleteReplacedDraft(replacesOrderId, outletId);
    */
  }

  Future<void> _deleteReplacedDraft(String? orderId, String outletId) async {
    if (orderId == null || orderId.isEmpty) return;
    try {
      await _client
          .from('orders')
          .delete()
          .eq('id', orderId)
          .eq('outlet_id', outletId)
          .eq('status', 'draft');
    } catch (_) {
      // Cleanup tidak boleh mengubah order baru menjadi gagal/dead-letter.
    }
  }

  Future<T> _withTransportFallback<T>(
    Future<T> Function(SupabaseClient client) operation,
  ) => BackendRequest.withFallback(client: _client, operation: operation);
}

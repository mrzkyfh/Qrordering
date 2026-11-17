import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../../shared/models/shift.dart';
import '../../../../shared/models/cash_movement.dart';
import '../../../../shared/models/shift_close_report.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/backend_request.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/receipt_builder.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../../../shared/services/supabase_service.dart';
import '../../../orders/data/datasources/orders_datasource.dart';
import 'pos_datasource.dart';

class ActiveShiftExistsException implements Exception {
  final Shift shift;
  const ActiveShiftExistsException(this.shift);

  String get message =>
      'Sesi kasir sejak ${DateFormat('dd/MM/yyyy HH:mm').format(shift.startTime.toLocal())} '
      'masih aktif. Sesi baru belum dibuat dan modal baru belum disimpan. '
      'Periksa dan tutup sesi tersebut melalui menu Tutup Kasir sebelum membuka sesi baru.';

  @override
  String toString() => message;
}

class PendingShiftCloseException implements Exception {
  const PendingShiftCloseException();

  @override
  String toString() =>
      'Penutupan kasir sebelumnya masih menunggu sinkronisasi. Sambungkan '
      'internet sebelum membuka kasir baru.';
}

class ShiftDatasource {
  static const _uuid = Uuid();

  // Getter agar pembacaan shift dari cache tetap bisa dipakai saat startup
  // offline sebelum Supabase siap melakukan request.
  SupabaseClient get _client => Supabase.instance.client;

  Shift? _cachedActiveShift(String outletId, String kasirId) {
    final matches = PosDatasource()
        .cachedOpenShifts(outletId)
        .where((entry) => entry['kasir_id'] == kasirId);
    if (matches.isEmpty) return null;
    final entry = matches.first;
    final id = entry['id'] as String?;
    final startedAt = DateTime.tryParse(entry['start_time'] as String? ?? '');
    if (id == null || id.isEmpty || startedAt == null) return null;
    return Shift(
      id: id,
      outletId: outletId,
      kasirId: kasirId,
      startTime: startedAt,
      openingCash: (entry['opening_cash'] as num?)?.toDouble() ?? 0,
      cashierName: entry['kasir_name'] as String?,
    );
  }

  /// Ambil pergerakan kas (masuk/keluar) untuk satu shift, terbaru dulu.
  Future<List<CashMovement>> fetchCashMovements(String shiftId) async {
    final pending = _pendingCashMovements(shiftId);
    if (!ConnectivityService.instance.online.value) {
      return _mergeCashMovements(
        PosDatasource().cachedCashMovements(shiftId),
        pending,
      );
    }
    try {
      final data = await _client
          .from('cash_movements')
          .select()
          .eq('shift_id', shiftId)
          .order('created_at', ascending: false);
      final server = (data as List)
          .map((e) => CashMovement.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      await PosDatasource().cacheCashMovements(shiftId, server);
      return _mergeCashMovements(server, pending);
    } catch (error) {
      if (!isBackendTemporarilyUnavailable(error)) rethrow;
      return _mergeCashMovements(
        PosDatasource().cachedCashMovements(shiftId),
        pending,
      );
    }
  }

  /// Shift kasir yang sedang terbuka untuk dipilih oleh role manajemen saat
  /// mencatat Kas Masuk/Keluar.
  Future<List<Shift>> fetchActiveShiftsForManagement(String outletId) async {
    if (!ConnectivityService.instance.online.value) {
      return PosDatasource()
          .cachedOpenShifts(outletId)
          .map((entry) => _shiftFromCache(entry, outletId))
          .whereType<Shift>()
          .toList();
    }
    final data = await _client
        .from('shifts')
        .select('*, staff:kasir_id(full_name)')
        .eq('outlet_id', outletId)
        .isFilter('end_time', null)
        .order('start_time', ascending: true);
    return (data as List).map((entry) => Shift.fromJson(entry)).toList();
  }

  /// Catat kas masuk/keluar. [type] = 'in' | 'out'.
  Future<CashMovement> addCashMovement({
    required String shiftId,
    required String outletId,
    required String type,
    required double amount,
    String? note,
    String expenseCategory = 'operasional',
  }) async {
    final requestId = _uuid.v4();
    final createdAt = ConnectivityService.instance.trustedUtcNow();
    if (!ConnectivityService.instance.online.value) {
      final expectedUserId = await _activeStaffId();
      return _queueCashMovement(
        requestId: requestId,
        shiftId: shiftId,
        outletId: outletId,
        type: type,
        amount: amount,
        note: note,
        expenseCategory: expenseCategory,
        expectedUserId: expectedUserId,
        createdAt: createdAt,
      );
    }
    try {
      return await replayCashMovement(
        requestId: requestId,
        shiftId: shiftId,
        outletId: outletId,
        type: type,
        amount: amount,
        note: note,
        expenseCategory: expenseCategory,
        createdAt: createdAt,
      );
    } catch (error) {
      if (!isBackendTemporarilyUnavailable(error)) rethrow;
      final expectedUserId = await _activeStaffId();
      return _queueCashMovement(
        requestId: requestId,
        shiftId: shiftId,
        outletId: outletId,
        type: type,
        amount: amount,
        note: note,
        expenseCategory: expenseCategory,
        expectedUserId: expectedUserId,
        createdAt: createdAt,
      );
    }
  }

  Future<String> _activeStaffId() async {
    final id = await SupabaseService().activeStaffIdForMutation();
    if (id == null || id.isEmpty) {
      throw StateError('Identitas staf aktif tidak tersedia');
    }
    return id;
  }

  Future<CashMovement> replayCashMovement({
    required String requestId,
    required String shiftId,
    required String outletId,
    required String type,
    required double amount,
    required DateTime createdAt,
    String? note,
    String expenseCategory = 'operasional',
  }) async {
    final data = await _client.rpc(
      'record_cash_movement_idempotent',
      params: {
        'p_request_id': requestId,
        'p_shift_id': shiftId,
        'p_outlet_id': outletId,
        'p_type': type,
        'p_amount': amount,
        'p_note': note,
        'p_expense_category': expenseCategory,
        'p_created_at': createdAt.toUtc().toIso8601String(),
      },
    );
    return CashMovement.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<CashMovement> _queueCashMovement({
    required String requestId,
    required String shiftId,
    required String outletId,
    required String type,
    required double amount,
    required String expenseCategory,
    required String expectedUserId,
    required DateTime createdAt,
    String? note,
  }) async {
    final movement = CashMovement(
      id: requestId,
      requestId: requestId,
      shiftId: shiftId,
      outletId: outletId,
      type: type,
      amount: amount,
      note: note,
      createdBy: expectedUserId,
      createdAt: createdAt.toUtc(),
    );
    await TransactionJournalService.instance.enqueue(
      id: 'cash-movement-$requestId',
      type: 'cash_movement',
      payload: {
        'requestId': requestId,
        'shiftId': shiftId,
        'outletId': outletId,
        'type': type,
        'amount': amount,
        'note': note,
        'expenseCategory': expenseCategory,
        'expectedUserId': expectedUserId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'clockSource': ConnectivityService.instance.hasTrustedServerClock
            ? 'server_offset'
            : 'device',
      },
    );
    final cached = PosDatasource().cachedCashMovements(shiftId);
    await PosDatasource().cacheCashMovements(
      shiftId,
      _mergeCashMovements(cached, [movement]),
    );
    return movement;
  }

  List<CashMovement> _pendingCashMovements(String shiftId) {
    return TransactionJournalService.instance
        .all(includeAttention: false)
        .where((entry) => entry['type'] == 'cash_movement')
        .map((entry) => entry['payload'])
        .whereType<Map>()
        .where((payload) => payload['shiftId'] == shiftId)
        .map((payload) {
          final createdAt = DateTime.tryParse(
            payload['createdAt']?.toString() ?? '',
          );
          final amount = payload['amount'];
          if (createdAt == null || amount is! num) return null;
          return CashMovement(
            id: payload['requestId']?.toString() ?? '',
            requestId: payload['requestId']?.toString(),
            shiftId: shiftId,
            outletId: payload['outletId']?.toString() ?? '',
            type: payload['type']?.toString() ?? '',
            amount: amount.toDouble(),
            note: payload['note'] as String?,
            createdBy: payload['expectedUserId'] as String?,
            createdAt: createdAt,
          );
        })
        .whereType<CashMovement>()
        .toList();
  }

  List<CashMovement> _mergeCashMovements(
    Iterable<CashMovement> saved,
    Iterable<CashMovement> pending,
  ) {
    final byId = <String, CashMovement>{
      for (final movement in saved) movement.requestId ?? movement.id: movement,
      for (final movement in pending)
        movement.requestId ?? movement.id: movement,
    };
    return byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Shift? _shiftFromCache(Map<String, dynamic> entry, String outletId) {
    final id = entry['id'] as String?;
    final kasirId = entry['kasir_id'] as String?;
    final startedAt = DateTime.tryParse(entry['start_time'] as String? ?? '');
    if (id == null || kasirId == null || startedAt == null) return null;
    return Shift(
      id: id,
      outletId: outletId,
      kasirId: kasirId,
      startTime: startedAt,
      openingCash: (entry['opening_cash'] as num?)?.toDouble() ?? 0,
      cashierName: entry['kasir_name'] as String?,
    );
  }

  Future<Shift?> fetchActiveShift(String outletId, String kasirId) async {
    if (!ConnectivityService.instance.online.value) {
      return _cachedActiveShift(outletId, kasirId);
    }
    dynamic data;
    try {
      data = await _client
          .from('shifts')
          .select()
          .eq('outlet_id', outletId)
          .eq('kasir_id', kasirId)
          .isFilter('end_time', null)
          .maybeSingle();
    } catch (_) {
      final cached = _cachedActiveShift(outletId, kasirId);
      if (cached != null) return cached;
      rethrow;
    }
    if (data == null) {
      // Respons server yang sah dan kosong berarti shift memang sudah tidak
      // aktif. Bersihkan cache lama agar tidak dipakai pada sesi offline
      // berikutnya.
      await PosDatasource().forgetOpenShift(
        outletId: outletId,
        kasirId: kasirId,
      );
      return null;
    }
    final shift = Shift.fromJson(data);
    await _rememberForOfflinePayment(shift);
    return shift;
  }

  Future<List<Shift>> fetchRecentShifts(String outletId, String kasirId) async {
    // Riwayat bukan syarat transaksi. Saat offline jangan membuat seluruh
    // halaman shift gagal hanya karena daftar tujuh hari tidak dapat dimuat.
    if (!ConnectivityService.instance.online.value) return const [];
    // Kolom timestamptz menyimpan UTC — kirim instan UTC, bukan jam dinding lokal.
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .toUtc()
        .toIso8601String();
    try {
      final data = await _client
          .from('shifts')
          .select()
          .eq('outlet_id', outletId)
          .eq('kasir_id', kasirId)
          .not('end_time', 'is', null)
          .gte('start_time', cutoff)
          .order('start_time', ascending: false)
          .limit(20);
      return (data as List).map((e) => Shift.fromJson(e)).toList();
    } catch (_) {
      // Gangguan jaringan dapat terjadi sebelum probe memperbarui flag online.
      // Riwayat bukan prasyarat untuk membaca/membuka shift aktif.
      return const [];
    }
  }

  Future<Shift> openShift(
    String outletId,
    String kasirId,
    double openingCash,
  ) async {
    final pendingClose = TransactionJournalService.instance.all().any((entry) {
      if (entry['type'] != 'shift_close') return false;
      final payload = entry['payload'];
      return payload is Map &&
          payload['outletId'] == outletId &&
          payload['expectedUserId'] == kasirId;
    });
    if (pendingClose) throw const PendingShiftCloseException();

    final shiftId = _uuid.v4();
    final startedAt = ConnectivityService.instance.trustedUtcNow();
    final clockSource = ConnectivityService.instance.hasTrustedServerClock
        ? 'server_offset'
        : 'device';

    if (!ConnectivityService.instance.online.value) {
      return _queueOfflineShiftOpen(
        shiftId: shiftId,
        outletId: outletId,
        kasirId: kasirId,
        openingCash: openingCash,
        startedAt: startedAt,
        clockSource: clockSource,
      );
    }

    try {
      return await replayOfflineShiftOpen(
        shiftId: shiftId,
        outletId: outletId,
        kasirId: kasirId,
        openingCash: openingCash,
        startedAt: startedAt,
      );
    } on PostgrestException catch (e) {
      // 23505: unique violation — kasir sudah punya shift terbuka di outlet ini.
      // Jangan laporkan sesi lama sebagai pembukaan baru yang sukses.
      if (e.code == '23505') {
        final existing = await fetchActiveShift(outletId, kasirId);
        if (existing != null) throw ActiveShiftExistsException(existing);
      }
      if (isBackendTemporarilyUnavailable(e)) {
        return _queueOfflineShiftOpen(
          shiftId: shiftId,
          outletId: outletId,
          kasirId: kasirId,
          openingCash: openingCash,
          startedAt: startedAt,
          clockSource: clockSource,
        );
      }
      rethrow;
    } catch (error) {
      if (!isBackendTemporarilyUnavailable(error)) rethrow;
      // RPC menggunakan UUID pilihan perangkat. Bila server sebenarnya sudah
      // menerima request tetapi respons terputus, replay ID yang sama hanya
      // mengembalikan shift tersebut dan tidak membuka laci kedua.
      return _queueOfflineShiftOpen(
        shiftId: shiftId,
        outletId: outletId,
        kasirId: kasirId,
        openingCash: openingCash,
        startedAt: startedAt,
        clockSource: clockSource,
      );
    }
  }

  /// Replay pembukaan shift yang dibuat perangkat. UUID ditentukan sebelum
  /// request sehingga aman dicoba ulang setelah timeout atau aplikasi mati.
  Future<Shift> replayOfflineShiftOpen({
    required String shiftId,
    required String outletId,
    required String kasirId,
    required double openingCash,
    required DateTime startedAt,
  }) async {
    final data = await _client.rpc(
      'open_shift_idempotent',
      params: {
        'p_shift_id': shiftId,
        'p_outlet_id': outletId,
        'p_kasir_id': kasirId,
        'p_opening_cash': openingCash,
        'p_started_at': startedAt.toUtc().toIso8601String(),
      },
    );
    final shift = Shift.fromJson(Map<String, dynamic>.from(data as Map));
    await _rememberForOfflinePayment(shift);
    return shift;
  }

  Future<Shift> _queueOfflineShiftOpen({
    required String shiftId,
    required String outletId,
    required String kasirId,
    required double openingCash,
    required DateTime startedAt,
    required String clockSource,
  }) async {
    final shift = Shift(
      id: shiftId,
      outletId: outletId,
      kasirId: kasirId,
      startTime: startedAt.toUtc(),
      openingCash: openingCash,
    );
    await TransactionJournalService.instance.enqueue(
      id: 'shift-open-$shiftId',
      type: 'shift_open',
      payload: {
        'shiftId': shiftId,
        'outletId': outletId,
        'kasirId': kasirId,
        'expectedUserId': kasirId,
        'openingCash': openingCash,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'clockSource': clockSource,
      },
    );
    await _rememberForOfflinePayment(shift);
    return shift;
  }

  /// Tutup shift lewat RPC — SERVER yang menghitung `expected_cash` &
  /// `cash_difference` dari opening + penjualan tunai + kas masuk/keluar.
  ///
  /// Dulu di sini di-UPDATE langsung dengan angka hasil hitungan APLIKASI. Dua
  /// akibatnya: (1) angka rekonsiliasi kas ditentukan klien — bug/manipulasi di
  /// aplikasi bisa menyembunyikan selisih laci; (2) rumusnya jadi salinan kedua
  /// di samping RPC close_shift yang dipakai owner-panel, dan keduanya sudah
  /// terlanjur melenceng (RPC lupa menghitung kas masuk/keluar). Satu rumus,
  /// satu tempat.
  ///
  /// RPC juga menolak shift yang sudah ditutup — guard yang dulu terlewat karena
  /// UPDATE di sini tak menyaring `end_time IS NULL`, sehingga shift tertutup
  /// bisa ditutup ulang dan angkanya tertimpa.
  Future<ShiftCloseReport> closeShift({
    required String shiftId,
    required double closingCash,
    String? notes,
  }) async {
    final snapshot = PosDatasource().cachedShiftSnapshotById(shiftId);
    final closedAt = ConnectivityService.instance.trustedUtcNow();
    final clockSource = ConnectivityService.instance.hasTrustedServerClock
        ? 'server_offset'
        : 'device';

    if (!ConnectivityService.instance.online.value) {
      if (snapshot == null) {
        throw StateError('Data shift lokal tidak tersedia untuk penutupan');
      }
      return _queueOfflineShiftClose(
        snapshot: snapshot,
        closingCash: closingCash,
        notes: notes,
        closedAt: closedAt,
        clockSource: clockSource,
      );
    }

    dynamic data;
    try {
      data = await replayOfflineShiftClose(
        shiftId: shiftId,
        closingCash: closingCash,
        notes: notes,
        closedAt: closedAt,
      );
    } catch (error) {
      if (!isBackendTemporarilyUnavailable(error)) rethrow;
      if (snapshot == null) rethrow;
      return _queueOfflineShiftClose(
        snapshot: snapshot,
        closingCash: closingCash,
        notes: notes,
        closedAt: closedAt,
        clockSource: clockSource,
      );
    }
    final report = ShiftCloseReport.fromJson(Map<String, dynamic>.from(data));
    await PosDatasource().forgetOpenShift(
      outletId: report.outletId,
      shiftId: report.shiftId,
      kasirId: report.cashierId,
    );
    return report;
  }

  Future<Map<String, dynamic>> replayOfflineShiftClose({
    required String shiftId,
    required double closingCash,
    required DateTime closedAt,
    String? notes,
  }) async {
    final data = await _client.rpc(
      'close_shift_idempotent_with_report',
      params: {
        'p_shift_id': shiftId,
        'p_closing_cash': closingCash,
        'p_notes': notes,
        'p_closed_at': closedAt.toUtc().toIso8601String(),
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<ShiftCloseReport> _queueOfflineShiftClose({
    required Map<String, dynamic> snapshot,
    required double closingCash,
    required DateTime closedAt,
    required String clockSource,
    String? notes,
  }) async {
    final shiftId = snapshot['id'] as String;
    final outletId = snapshot['outlet_id'] as String;
    final kasirId = snapshot['kasir_id'] as String;
    await TransactionJournalService.instance.enqueue(
      id: 'shift-close-$shiftId',
      type: 'shift_close',
      payload: {
        'shiftId': shiftId,
        'outletId': outletId,
        'expectedUserId': kasirId,
        'closingCash': closingCash,
        'notes': notes,
        'closedAt': closedAt.toUtc().toIso8601String(),
        'clockSource': clockSource,
      },
    );
    final report = await _buildProvisionalCloseReport(
      snapshot: snapshot,
      closingCash: closingCash,
      closedAt: closedAt,
      notes: notes,
    );
    // Setelah kasir menekan tutup, perangkat tidak boleh menerima transaksi
    // baru pada laci tersebut walaupun replay server masih menunggu internet.
    await PosDatasource().forgetOpenShift(
      outletId: outletId,
      shiftId: shiftId,
      kasirId: kasirId,
    );
    return report;
  }

  Future<ShiftCloseReport> _buildProvisionalCloseReport({
    required Map<String, dynamic> snapshot,
    required double closingCash,
    required DateTime closedAt,
    String? notes,
  }) async {
    final shiftId = snapshot['id'] as String;
    final outletId = snapshot['outlet_id'] as String;
    final kasirId = snapshot['kasir_id'] as String;
    final openingCash = (snapshot['opening_cash'] as num?)?.toDouble() ?? 0;
    final orders = OrdersDatasource();
    final completed = (await orders.fetchCompletedOrders(
      outletId,
    )).where((order) => order.shiftId == shiftId).toList();
    final active = (await orders.fetchActiveOrders(
      outletId,
    )).where((order) => order.shiftId == shiftId).toList();
    final movements = await fetchCashMovements(shiftId);

    final paymentTotals = <PaymentMethod, double>{};
    for (final order in completed) {
      for (final payment in order.payments ?? const []) {
        paymentTotals.update(
          payment.method,
          (value) => value + payment.amount,
          ifAbsent: () => payment.amount,
        );
      }
    }
    final cashReceived = paymentTotals[PaymentMethod.cash] ?? 0;
    final totalReceipts = paymentTotals.values.fold<double>(0, (a, b) => a + b);
    final products = <String, ({int quantity, double amount})>{};
    for (final order in completed) {
      for (final item in order.items ?? const []) {
        final name = item.menuItem?.name ?? 'Menu';
        final previous = products[name];
        products[name] = (
          quantity: ((previous?.quantity ?? 0) + item.quantity).toInt(),
          amount: (previous?.amount ?? 0) + item.subtotal,
        );
      }
    }
    final outletMap =
        PosDatasource().cachedOutletReceiptMap(outletId) ??
        <String, dynamic>{'name': 'Outlet'};
    final cashIn = movements
        .where((movement) => movement.isIn)
        .fold<double>(0, (sum, movement) => sum + movement.amount);
    final cashOut = movements
        .where((movement) => !movement.isIn)
        .fold<double>(0, (sum, movement) => sum + movement.amount);
    final expectedCash = openingCash + cashReceived + cashIn - cashOut;
    return ShiftCloseReport(
      shiftId: shiftId,
      outletId: outletId,
      outlet: OutletReceiptInfo.fromMap(outletMap),
      cashierId: kasirId,
      cashierName: snapshot['kasir_name'] as String? ?? 'Kasir',
      openedAt: DateTime.parse(snapshot['start_time'] as String),
      closedAt: closedAt,
      openingCash: openingCash,
      closingCash: closingCash,
      expectedCash: expectedCash,
      cashDifference: closingCash - expectedCash,
      cashReceived: cashReceived,
      nonCashReceived: totalReceipts - cashReceived,
      totalReceipts: totalReceipts,
      taxTotal: completed.fold(0, (sum, order) => sum + order.taxAmount),
      serviceChargeTotal: completed.fold(
        0,
        (sum, order) => sum + order.serviceCharge,
      ),
      discountTotal: completed.fold(
        0,
        (sum, order) => sum + order.discountAmount,
      ),
      refundTotal: 0,
      cashIn: cashIn,
      cashOut: cashOut,
      completedTransactions: completed.length,
      unpaidTransactions: active.length,
      voidItemQuantity: 0,
      voidItemAmount: 0,
      productQuantity: products.values.fold(
        0,
        (sum, value) => sum + value.quantity,
      ),
      paymentMethods: [
        for (final entry in paymentTotals.entries)
          ShiftPaymentSummary(method: entry.key.value, amount: entry.value),
      ],
      products: [
        for (final entry in products.entries)
          ShiftProductSummary(
            name: entry.key,
            quantity: entry.value.quantity,
            amount: entry.value.amount,
          ),
      ],
      notes: notes,
      isProvisional: true,
    );
  }

  Future<void> _rememberForOfflinePayment(Shift shift) =>
      PosDatasource().rememberOpenShift(
        outletId: shift.outletId,
        shiftId: shift.id,
        kasirId: shift.kasirId,
        kasirName: shift.cashierName,
        startTime: shift.startTime,
        openingCash: shift.openingCash,
      );

  /// Muat ulang laporan shift tertutup untuk pratinjau atau cetak ulang.
  Future<ShiftCloseReport> fetchCloseReport(String shiftId) async {
    final data = await _client.rpc(
      'get_shift_close_report',
      params: {'p_shift_id': shiftId},
    );
    return ShiftCloseReport.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<double> calculateExpectedCash(
    String shiftId,
    double openingCash,
  ) async {
    // Kas masuk/keluar manual (petty cash) — dihitung terpisah dari penjualan.
    final movements = await fetchCashMovements(shiftId);
    final movementNet = movements.fold(0.0, (sum, m) => sum + m.signedAmount);

    final orders = await _client
        .from('orders')
        .select('id')
        .eq('shift_id', shiftId)
        .eq('status', 'paid');

    final orderIds = (orders as List).map((o) => o['id'] as String).toList();
    if (orderIds.isEmpty) return openingCash + movementNet;

    final payments = await _client
        .from('payments')
        .select('amount')
        .inFilter('order_id', orderIds)
        .eq('method', 'cash');

    final cashTotal = (payments as List).fold(
      0.0,
      (sum, p) => sum + (p['amount'] as num).toDouble(),
    );

    // Refund TUNAI mengeluarkan uang dari laci → kurangi (selaras server
    // close_shift, migrasi 147). Refund non-tunai tak menyentuh laci.
    final refunds = await _client
        .from('refunds')
        .select('amount')
        .inFilter('order_id', orderIds)
        .eq('method', 'cash');

    final refundCash = (refunds as List).fold(
      0.0,
      (sum, r) => sum + (r['amount'] as num).toDouble(),
    );
    return openingCash + cashTotal - refundCash + movementNet;
  }
}

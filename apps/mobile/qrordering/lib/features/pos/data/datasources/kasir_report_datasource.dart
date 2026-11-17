import 'package:supabase_flutter/supabase_flutter.dart';

/// Datasource laporan kasir (outlet-scoped), meniru report center referensi:
/// Ringkasan Penjualan, Kas Kasir, Kasir (shift), Void, Jenis Bayar,
/// Produk Terjual, 10 Teratas. Semua read-only.
class KasirReportDatasource {
  final _client = Supabase.instance.client;

  // ─── Ringkasan Penjualan ──────────────────────────────────────────────────

  /// Kartu ringkasan: total penjualan, transaksi, laba kotor, produk, terima
  /// pembayaran, refund, dan rata-rata/transaksi.
  Future<Map<String, dynamic>> fetchSummary(
    String outletId,
    String from,
    String to,
    String fromIso,
    String toIso,
  ) async {
    final salesData = await _client
        .from('v_daily_sales')
        .select()
        .eq('outlet_id', outletId)
        .gte('sale_date', from)
        .lte('sale_date', to);

    double totalRevenue = 0;
    int totalOrders = 0;
    for (final r in List<Map<String, dynamic>>.from(salesData)) {
      totalRevenue += (r['net_revenue'] as num?)?.toDouble() ?? 0;
      totalOrders += (r['total_orders'] as num?)?.toInt() ?? 0;
    }

    // HPP authoritative dari resep efektif + weighted average cost di server.
    // View sudah mengurangi qty item yang direfund.
    final hppData = await _client
        .from('v_order_hpp_unified')
        .select('hpp_total')
        .eq('outlet_id', outletId)
        .eq('status', 'paid')
        .gte('created_at', fromIso)
        .lte('created_at', toIso);
    double totalHpp = 0;
    for (final r in List<Map<String, dynamic>>.from(hppData)) {
      totalHpp += (r['hpp_total'] as num?)?.toDouble() ?? 0;
    }

    // Total produk terjual
    final items = await _client
        .from('v_top_menu_items')
        .select('qty_sold')
        .eq('outlet_id', outletId)
        .gte('sale_date', from)
        .lte('sale_date', to);
    int totalProducts = 0;
    for (final i in List<Map<String, dynamic>>.from(items)) {
      totalProducts += (i['qty_sold'] as num?)?.toInt() ?? 0;
    }

    // Terima pembayaran dari transaksi aktif + arsip.
    final payments = await _client
        .from('v_payment_received_daily')
        .select('total_amount')
        .eq('outlet_id', outletId)
        .gte('pay_date', from)
        .lte('pay_date', to);
    double paymentReceived = 0;
    for (final p in List<Map<String, dynamic>>.from(payments)) {
      paymentReceived += (p['total_amount'] as num?)?.toDouble() ?? 0;
    }

    // Refund (cancelled orders)
    final refunds = await _client
        .from('orders')
        .select('total_amount')
        .eq('outlet_id', outletId)
        .eq('status', 'cancelled')
        .gte('cancelled_at', fromIso)
        .lte('cancelled_at', toIso);
    double refundTotal = 0;
    for (final r in List<Map<String, dynamic>>.from(refunds)) {
      refundTotal += (r['total_amount'] as num?)?.toDouble() ?? 0;
    }

    // Refund SEBAGIAN (order tetap paid) — dari tabel refunds.
    final partial = await _client
        .from('v_partial_refund_summary')
        .select('total_amount')
        .eq('outlet_id', outletId)
        .gte('refund_date', from)
        .lte('refund_date', to);
    for (final r in List<Map<String, dynamic>>.from(partial)) {
      refundTotal += (r['total_amount'] as num?)?.toDouble() ?? 0;
    }

    return {
      'total_revenue': totalRevenue,
      'total_orders': totalOrders,
      'gross_profit': totalRevenue - totalHpp,
      'cost_of_goods': totalHpp,
      'total_products': totalProducts,
      'payment_received': paymentReceived,
      'refund_total': refundTotal,
      'avg_transaction': totalOrders > 0 ? totalRevenue / totalOrders : 0,
    };
  }

  /// Pendapatan per jam (untuk bar chart jam sibuk).
  Future<List<Map<String, dynamic>>> fetchPeakHours(
    String outletId,
    String from,
    String to,
  ) async {
    final data = await _client
        .from('v_peak_hours')
        .select()
        .eq('outlet_id', outletId)
        .gte('sale_date', from)
        .lte('sale_date', to);

    // Agregasi per jam (lintas tanggal)
    final byHour = <int, double>{};
    for (final r in List<Map<String, dynamic>>.from(data)) {
      final h = (r['hour_of_day'] as num?)?.toInt() ?? 0;
      byHour[h] =
          (byHour[h] ?? 0) + ((r['total_revenue'] as num?)?.toDouble() ?? 0);
    }
    return [
      for (int h = 0; h < 24; h++) {'hour': h, 'revenue': byHour[h] ?? 0.0},
    ];
  }

  // ─── 10 Teratas / Produk Terjual ─────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchTopProducts(
    String outletId,
    String from,
    String to, {
    int? limit,
  }) async {
    var q = _client
        .from('v_top_menu_items')
        .select()
        .eq('outlet_id', outletId)
        .gte('sale_date', from)
        .lte('sale_date', to);
    final data = await q;

    // Agregasi per menu lintas tanggal
    final map = <String, Map<String, dynamic>>{};
    for (final r in List<Map<String, dynamic>>.from(data)) {
      final name = r['menu_item_name'] as String? ?? '-';
      final e = map.putIfAbsent(
        name,
        () => {
          'name': name,
          'qty': 0,
          'revenue': 0.0,
          'category': r['category_name'],
        },
      );
      e['qty'] = (e['qty'] as int) + ((r['qty_sold'] as num?)?.toInt() ?? 0);
      e['revenue'] =
          (e['revenue'] as double) +
          ((r['total_revenue'] as num?)?.toDouble() ?? 0);
    }
    final list = map.values.toList()
      ..sort((a, b) => (b['qty'] as int).compareTo(a['qty'] as int));
    return limit != null ? list.take(limit).toList() : list;
  }

  // ─── Jenis Bayar ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchPaymentBreakdown(
    String outletId,
    String from,
    String to,
  ) async {
    final data = await _client
        .from('v_payment_summary')
        .select()
        .eq('outlet_id', outletId)
        .gte('pay_date', from)
        .lte('pay_date', to);

    final map = <String, Map<String, dynamic>>{};
    double grand = 0;
    for (final r in List<Map<String, dynamic>>.from(data)) {
      final m = r['method'] as String? ?? '-';
      final amt = (r['total_amount'] as num?)?.toDouble() ?? 0;
      final cnt = (r['total_transactions'] as num?)?.toInt() ?? 0;
      grand += amt;
      final e = map.putIfAbsent(
        m,
        () => {'method': m, 'total': 0.0, 'count': 0},
      );
      e['total'] = (e['total'] as double) + amt;
      e['count'] = (e['count'] as int) + cnt;
    }
    final list = map.values.toList()
      ..sort((a, b) => (b['total'] as double).compareTo(a['total'] as double));
    for (final e in list) {
      e['percentage'] = grand > 0 ? (e['total'] as double) / grand * 100 : 0.0;
    }
    return list;
  }

  // ─── Kasir (Shift) ────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchShifts(
    String outletId,
    String fromIso,
    String toIso, {
    String? kasirId,
  }) async {
    var query = _client
        .from('shifts')
        .select('*, staff:kasir_id(full_name)')
        .eq('outlet_id', outletId)
        .gte('start_time', fromIso)
        .lte('start_time', toIso);
    if (kasirId != null) query = query.eq('kasir_id', kasirId);
    final raw = await query.order('start_time', ascending: false);
    return List<Map<String, dynamic>>.from(raw)
        .map((r) => {...r, 'kasir_name': (r['staff'] as Map?)?['full_name']})
        .toList();
  }

  // ─── Void ─────────────────────────────────────────────────────────────────

  Future<({List<Map<String, dynamic>> orders, double total})> fetchVoidReport(
    String outletId,
    String fromIso,
    String toIso,
  ) async {
    final params = {
      'p_outlet_id': outletId,
      'p_date_from': fromIso,
      'p_date_to': toIso,
    };
    final results = await Future.wait([
      _client.rpc('report_void_summary', params: params),
      _client.rpc(
        'report_void_details',
        params: {...params, 'p_limit': 500, 'p_offset': 0},
      ),
    ]);

    final summaryRows = List<Map<String, dynamic>>.from(
      results[0] as List? ?? const [],
    );
    final detailRows = List<Map<String, dynamic>>.from(
      results[1] as List? ?? const [],
    );
    final total = summaryRows.isEmpty
        ? 0.0
        : (summaryRows.first['total_amount'] as num?)?.toDouble() ?? 0.0;
    final orders = detailRows.map((row) {
      return <String, dynamic>{
        ...row,
        'id': row['order_id'],
        'voided_at': row['status_at'],
        'created_at': row['order_at'],
        // Nilai historis void. Jangan memakai orders.total_amount karena
        // nilainya memang menjadi nol setelah seluruh item di-void.
        'void_amount': row['subtotal'],
      };
    }).toList();
    return (orders: orders, total: total);
  }

  // ─── Refund (order cancelled) ─────────────────────────────────────────────
  Future<({List<Map<String, dynamic>> orders, double total})> fetchRefundReport(
    String outletId,
    String fromIso,
    String toIso,
  ) async {
    final raw = await _client
        .from('orders')
        .select(
          'id, order_number, order_type, total_amount, created_at, cancelled_at, '
          'cancel_reason, kasir:created_by(full_name), authorizer:cancelled_by(full_name)',
        )
        .eq('outlet_id', outletId)
        .eq('status', 'cancelled')
        .gte('cancelled_at', fromIso)
        .lte('cancelled_at', toIso)
        .order('cancelled_at', ascending: false);

    final orders = List<Map<String, dynamic>>.from(raw);
    double total = 0;
    for (final o in orders) {
      total += (o['total_amount'] as num?)?.toDouble() ?? 0;
      o['kasir_name'] = (o['kasir'] as Map?)?['full_name'];
      o['otorisasi_name'] =
          (o['authorizer'] as Map?)?['full_name'] ??
          (o['kasir'] as Map?)?['full_name'];
    }
    return (orders: orders, total: total);
  }

  // ─── Kas Kasir ────────────────────────────────────────────────────────────

  /// Ringkasan kas: pemasukan/pengeluaran manual (belum ada → 0), refund,
  /// total kas kasir (modal + tunai diterima), total penjualan, + baris shift.
  Future<Map<String, dynamic>> fetchKasKasir(
    String outletId,
    String from,
    String to,
    String fromIso,
    String toIso, {
    String? kasirId,
  }) async {
    var shiftQuery = _client
        .from('shifts')
        .select(
          'id, opening_cash, closing_cash, start_time, staff:kasir_id(full_name)',
        )
        .eq('outlet_id', outletId)
        .gte('start_time', fromIso)
        .lte('start_time', toIso);
    if (kasirId != null) shiftQuery = shiftQuery.eq('kasir_id', kasirId);
    final shifts = await shiftQuery.order('start_time', ascending: false);
    final shiftRows = List<Map<String, dynamic>>.from(shifts);

    double opening = 0;
    for (final s in shiftRows) {
      opening += (s['opening_cash'] as num?)?.toDouble() ?? 0;
    }

    // Tunai diterima dari v_shift_summary
    double cashReceived = 0;
    if (shiftRows.isNotEmpty) {
      final summary = await _client
          .from('v_shift_summary')
          .select('cash_received')
          .inFilter('shift_id', shiftRows.map((s) => s['id']).toList());
      for (final s in List<Map<String, dynamic>>.from(summary)) {
        cashReceived += (s['cash_received'] as num?)?.toDouble() ?? 0;
      }
    }

    double totalSales = 0;
    if (kasirId != null) {
      final sales = await _client
          .from('v_kasir_performance')
          .select('total_revenue')
          .eq('outlet_id', outletId)
          .eq('kasir_id', kasirId)
          .gte('work_date', from)
          .lte('work_date', to);
      for (final r in List<Map<String, dynamic>>.from(sales)) {
        totalSales += (r['total_revenue'] as num?)?.toDouble() ?? 0;
      }
    } else {
      final sales = await _client
          .from('v_daily_sales')
          .select('net_revenue')
          .eq('outlet_id', outletId)
          .gte('sale_date', from)
          .lte('sale_date', to);
      for (final r in List<Map<String, dynamic>>.from(sales)) {
        totalSales += (r['net_revenue'] as num?)?.toDouble() ?? 0;
      }
    }

    // Refund
    double refundTotal = 0;
    if (kasirId != null) {
      if (shiftRows.isNotEmpty) {
        final refunds = await _client
            .from('orders')
            .select('total_amount')
            .inFilter('shift_id', shiftRows.map((s) => s['id']).toList())
            .eq('status', 'cancelled');
        for (final r in List<Map<String, dynamic>>.from(refunds)) {
          refundTotal += (r['total_amount'] as num?)?.toDouble() ?? 0;
        }
      }
    } else {
      final refunds = await _client
          .from('orders')
          .select('total_amount')
          .eq('outlet_id', outletId)
          .eq('status', 'cancelled')
          .gte('cancelled_at', fromIso)
          .lte('cancelled_at', toIso);
      for (final r in List<Map<String, dynamic>>.from(refunds)) {
        refundTotal += (r['total_amount'] as num?)?.toDouble() ?? 0;
      }
    }

    // Kas masuk/keluar manual (cash_movements) untuk periode ini.
    List<dynamic> movements = const [];
    if (kasirId == null || shiftRows.isNotEmpty) {
      var movementQuery = _client
          .from('cash_movements')
          .select('id, shift_id, type, amount, note, created_at')
          .eq('outlet_id', outletId)
          .gte('created_at', fromIso)
          .lte('created_at', toIso);
      if (kasirId != null) {
        movementQuery = movementQuery.inFilter(
          'shift_id',
          shiftRows.map((s) => s['id']).toList(),
        );
      }
      movements = await movementQuery.order('created_at', ascending: false);
    }
    final movRows = List<Map<String, dynamic>>.from(movements);
    double pemasukan = 0, pengeluaran = 0;
    for (final m in movRows) {
      final amt = (m['amount'] as num?)?.toDouble() ?? 0;
      if (m['type'] == 'in') {
        pemasukan += amt;
      } else {
        pengeluaran += amt;
      }
    }

    return {
      'pemasukan': pemasukan,
      'pengeluaran': pengeluaran,
      'refund_total': refundTotal,
      'total_kas': opening + cashReceived,
      'total_penjualan': totalSales,
      'movements': movRows,
      'shifts': shiftRows
          .map(
            (s) => {
              'kasir_name': (s['staff'] as Map?)?['full_name'] ?? 'Kasir',
              'opening_cash': (s['opening_cash'] as num?)?.toDouble() ?? 0,
              'start_time': s['start_time'],
            },
          )
          .toList(),
    };
  }

  /// Semua kas masuk/keluar (cash_movements) di outlet untuk periode — dipakai
  /// laporan Kasir (net per shift + detail transaksi).
  Future<List<Map<String, dynamic>>> fetchAllMovements(
    String outletId,
    String fromIso,
    String toIso, {
    List<String>? shiftIds,
  }) async {
    if (shiftIds != null && shiftIds.isEmpty) return [];
    var query = _client
        .from('cash_movements')
        .select('shift_id, type, amount, note, created_at')
        .eq('outlet_id', outletId)
        .gte('created_at', fromIso)
        .lte('created_at', toIso);
    if (shiftIds != null) query = query.inFilter('shift_id', shiftIds);
    final rows = await query.order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  }
}

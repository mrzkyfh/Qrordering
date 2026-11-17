import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/app_skeleton.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../../shared/models/enums.dart';
import '../../data/datasources/kasir_report_datasource.dart';
import 'kasir_shell.dart';
import '../widgets/report_common.dart';
import '../../../orders/presentation/pages/order_list_page.dart';
import 'shift_page.dart';

class KasirReportPage extends StatefulWidget {
  final int initialCategory;

  /// Bila diisi → hanya kategori index ini yang bisa dipilih.
  final List<int>? allowedCategories;
  const KasirReportPage({
    super.key,
    this.initialCategory = 0,
    this.allowedCategories,
  });

  @override
  State<KasirReportPage> createState() => _KasirReportPageState();
}

const _categories = <(String, IconData)>[
  ('Ringkasan Penjualan', Icons.summarize_outlined),
  ('10 Laporan Teratas', Icons.leaderboard_outlined),
  ('Void', Icons.block_outlined),
  ('Kasir', Icons.badge_outlined),
  ('Kas Kasir', Icons.account_balance_wallet_outlined),
  ('Produk Terjual', Icons.fastfood_outlined),
  ('Jenis Bayar', Icons.payments_outlined),
  ('Daftar Order', Icons.receipt_long_outlined),
  ('Refund', Icons.assignment_return_outlined),
];

const _daftarOrderIndex = 7;
const _refundIndex = 8;

const _periodLabel = {
  'harian': 'Hari ini',
  'mingguan': 'Minggu ini',
  'bulanan': 'Bulan ini',
  'custom': 'Pilih tanggal',
};

// Stat card data model
class _CardItem {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final String? subtitle;
  final double accentOpacity;
  final bool muted; // nilai 0 → abu

  const _CardItem(
    this.icon,
    this.label,
    this.value,
    this.accent, {
    this.subtitle,
    this.accentOpacity = 1.0,
    this.muted = false,
  });
}

class _KasirReportPageState extends State<KasirReportPage> {
  final _ds = KasirReportDatasource();
  int _selected = 0;
  String _period = 'bulanan';
  int _offset = 0;
  ReportRange? _customRange;
  bool _loading = true;
  String? _error;
  String _outletId = '';
  String _kasirId = '';
  bool _isKasir = false;

  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _peakHours = [];
  List<Map<String, dynamic>> _topProducts = [];
  List<Map<String, dynamic>> _voidOrders = [];
  double _voidTotal = 0;
  List<Map<String, dynamic>> _refundOrders = [];
  double _refundTotal = 0;
  List<Map<String, dynamic>> _shifts = [];
  List<Map<String, dynamic>> _movements =
      []; // kas masuk/keluar (laporan Kasir)
  Map<String, dynamic> _kasKasir = {};
  List<Map<String, dynamic>> _payments = [];

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) {
      _outletId = auth.profile.outletId ?? '';
      _kasirId = auth.profile.id;
      _isKasir = auth.profile.role.value == 'kasir';
    }
    final allowed = widget.allowedCategories;
    _selected = (allowed != null && allowed.isNotEmpty)
        ? allowed.first
        : widget.initialCategory.clamp(0, _categories.length - 1);
    if (_isKasir && (allowed == null || allowed.isEmpty)) {
      _selected = 3;
    }
    _load();
  }

  List<int>? get _effectiveAllowed =>
      widget.allowedCategories ?? (_isKasir ? const [3] : null);

  ReportRange get _activeRange =>
      _customRange ?? computeRange(_period, _offset);

  Future<void> _load() async {
    if (_outletId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = _activeRange;
      switch (_selected) {
        case 0:
          final res = await Future.wait([
            _ds.fetchSummary(_outletId, r.from, r.to, r.fromIso, r.toIso),
            _ds.fetchPeakHours(_outletId, r.from, r.to),
            _ds.fetchPaymentBreakdown(_outletId, r.from, r.to),
            _ds.fetchTopProducts(_outletId, r.from, r.to),
          ]);
          _summary = res[0] as Map<String, dynamic>;
          _peakHours = res[1] as List<Map<String, dynamic>>;
          _payments = res[2] as List<Map<String, dynamic>>;
          _topProducts = res[3] as List<Map<String, dynamic>>;
          break;
        case 1:
          _topProducts = await _ds.fetchTopProducts(
            _outletId,
            r.from,
            r.to,
            limit: 10,
          );
          break;
        case 2:
          final v = await _ds.fetchVoidReport(_outletId, r.fromIso, r.toIso);
          _voidOrders = v.orders;
          _voidTotal = v.total;
          break;
        case 3:
          _shifts = await _ds.fetchShifts(
            _outletId,
            r.fromIso,
            r.toIso,
            kasirId: _isKasir ? _kasirId : null,
          );
          _movements = _isKasir
              ? []
              : await _ds.fetchAllMovements(_outletId, r.fromIso, r.toIso);
          break;
        case 4:
          _kasKasir = await _ds.fetchKasKasir(
            _outletId,
            r.from,
            r.to,
            r.fromIso,
            r.toIso,
            kasirId: _isKasir ? _kasirId : null,
          );
          break;
        case 5:
          _topProducts = await _ds.fetchTopProducts(_outletId, r.from, r.to);
          break;
        case 6:
          _payments = await _ds.fetchPaymentBreakdown(_outletId, r.from, r.to);
          break;
        case _refundIndex:
          final rf = await _ds.fetchRefundReport(_outletId, r.fromIso, r.toIso);
          _refundOrders = rf.orders;
          _refundTotal = rf.total;
          break;
      }
    } catch (e) {
      _error = humanizeError(e, fallback: 'Gagal memuat laporan.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectCategory(int i) {
    if (i == _selected) return;
    setState(() => _selected = i);
    _load();
  }

  Future<void> _onPeriodChanged(String period) async {
    if (period == 'custom') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2022),
        lastDate: DateTime(now.year, now.month, now.day),
        initialDateRange: _customRange == null
            ? DateTimeRange(
                start: DateTime(
                  now.year,
                  now.month,
                  now.day,
                ).subtract(const Duration(days: 6)),
                end: DateTime(now.year, now.month, now.day),
              )
            : DateTimeRange(
                start: DateTime.parse(_customRange!.from),
                end: DateTime.parse(_customRange!.to),
              ),
        helpText: 'Pilih periode laporan',
        saveText: 'Terapkan',
      );
      if (picked == null || !mounted) return;
      setState(() {
        _period = 'custom';
        _offset = 0;
        _customRange = ReportRange(
          _dateYmd(picked.start),
          _dateYmd(picked.end),
          '${_dateLabel(picked.start)} – ${_dateLabel(picked.end)}',
        );
      });
      _load();
      return;
    }
    setState(() {
      _period = period;
      _offset = 0;
      _customRange = null;
    });
    _load();
  }

  static String _dateYmd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _dateLabel(DateTime d) =>
      DateFormat('d MMM yyyy', 'id_ID').format(d);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final catLabel = _categories[_selected].$1;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.menu, size: 22),
          onPressed: KasirShell.openMenu,
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Laporan Penjualan',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              'Ringkasan performa penjualan toko Anda',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.border),
        ),
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 200,
                  child: _Sidebar(
                    selected: _selected,
                    onSelect: _selectCategory,
                    allowed: _effectiveAllowed,
                  ),
                ),
                const VerticalDivider(width: 1, color: AppColors.border),
                Expanded(child: _buildContentArea(catLabel)),
              ],
            )
          : Column(
              children: [
                _CategoryChips(
                  selected: _selected,
                  onSelect: _selectCategory,
                  allowed: _effectiveAllowed,
                ),
                Expanded(child: _buildContentArea(catLabel)),
              ],
            ),
    );
  }

  Widget _buildContentArea(String catLabel) {
    if (_selected == _daftarOrderIndex) return const OrderTablePage();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FilterBar(
          period: _period,
          label: _activeRange.label,
          offset: _offset,
          loading: _loading,
          onRefresh: _load,
          onPeriodChanged: _onPeriodChanged,
          onOffsetChanged: (o) {
            setState(() => _offset = o);
            _load();
          },
          canNavigate: _period != 'custom',
        ),
        Expanded(
          child: _loading
              ? const ListSkeleton()
              : _error != null
              ? ReportError(message: _error!, onRetry: _load)
              : _buildReport(),
        ),
      ],
    );
  }

  Widget _buildReport() {
    return switch (_selected) {
      0 => _buildRingkasan(),
      1 => _buildTopProducts(top10: true),
      2 => _buildVoid(),
      3 => _buildKasir(),
      4 => _buildKasKasir(),
      5 => _buildTopProducts(top10: false),
      _refundIndex => _buildRefund(),
      _ => _buildJenisBayar(),
    };
  }

  // ─── Ringkasan Penjualan ─────────────────────────────────────────────────────
  Widget _buildRingkasan() {
    const red = Color(0xFFE24B4A);
    const green = Color(0xFF1D9E75);
    const gray = Color(0xFFE5E5E5);

    final s = _summary;
    final revenue = (s['total_revenue'] as num?)?.toDouble() ?? 0;
    final orders = (s['total_orders'] as num?)?.toInt() ?? 0;
    final products = (s['total_products'] as num?)?.toInt() ?? 0;
    final hpp = (s['cost_of_goods'] as num?)?.toDouble() ?? 0;
    final grossProfit = (s['gross_profit'] as num?)?.toDouble() ?? 0;
    final received = (s['payment_received'] as num?)?.toDouble() ?? 0;
    final refund = (s['refund_total'] as num?)?.toDouble() ?? 0;
    final avg = orders > 0 ? revenue / orders : 0.0;
    final avgItems = orders > 0 ? products / orders : 0.0;

    final cards = [
      _CardItem(
        Icons.shopping_bag_outlined,
        'Total Penjualan',
        CurrencyFormatter.format(revenue),
        red,
        subtitle: 'penjualan bersih',
      ),
      _CardItem(
        Icons.shopping_cart_outlined,
        'Total Transaksi',
        '$orders',
        red,
        subtitle: 'order selesai',
        accentOpacity: 0.4,
      ),
      _CardItem(
        Icons.account_balance_wallet_outlined,
        'Rata-rata Transaksi',
        CurrencyFormatter.format(avg),
        red,
        subtitle: 'per order',
        accentOpacity: 0.4,
      ),
      _CardItem(
        Icons.inventory_2_outlined,
        'Produk Terjual',
        '$products',
        red,
        subtitle: 'item terjual',
        accentOpacity: 0.4,
      ),
      _CardItem(
        Icons.shopping_basket_outlined,
        'HPP',
        CurrencyFormatter.format(hpp),
        red,
        subtitle: 'harga pokok penjualan',
        accentOpacity: 0.4,
      ),
      _CardItem(
        Icons.trending_up_outlined,
        'Laba Kotor',
        CurrencyFormatter.format(grossProfit),
        grossProfit >= 0 ? green : red,
        subtitle: 'penjualan bersih − HPP',
      ),
      _CardItem(
        Icons.credit_card_outlined,
        'Terima Pembayaran',
        CurrencyFormatter.format(received),
        green,
        subtitle: 'total diterima',
      ),
      _CardItem(
        Icons.autorenew_rounded,
        'Refund',
        CurrencyFormatter.format(refund),
        refund > 0 ? red : gray,
        subtitle: refund > 0 ? 'dana dikembalikan' : 'tidak ada refund',
        accentOpacity: refund > 0 ? 0.4 : 1.0,
        muted: refund <= 0,
      ),
      _CardItem(
        Icons.receipt_outlined,
        'Order/Transaksi',
        avgItems.toStringAsFixed(1),
        red,
        subtitle: 'rata-rata item',
        accentOpacity: 0.4,
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statGrid(cards),
        const SizedBox(height: 14),
        _ChartCard(peakHours: _peakHours),
        const SizedBox(height: 14),
        _buildBottomRow(),
      ],
    );
  }

  Widget _buildBottomRow() {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _MetodePembayaranCard(payments: _payments)),
              const SizedBox(width: 12),
              Expanded(child: _KategoriCard(topProducts: _topProducts)),
            ],
          );
        }
        return Column(
          children: [
            _MetodePembayaranCard(payments: _payments),
            const SizedBox(height: 12),
            _KategoriCard(topProducts: _topProducts),
          ],
        );
      },
    );
  }

  // ─── 10 Teratas / Produk Terjual ────────────────────────────────────────────
  Widget _buildTopProducts({required bool top10}) {
    final totalRevenue = _topProducts.fold<double>(
      0,
      (s, e) => s + ((e['revenue'] as num?)?.toDouble() ?? 0),
    );
    final totalQty = _topProducts.fold<int>(
      0,
      (s, e) => s + ((e['qty'] as num?)?.toInt() ?? 0),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Total Pendapatan',
                value: CurrencyFormatter.format(totalRevenue),
                accent: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Produk Terjual',
                value: '$totalQty',
                accent: AppColors.info,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_topProducts.isEmpty)
          const ReportEmpty(
            icon: Icons.fastfood_outlined,
            message: 'Belum ada produk terjual pada periode ini.',
          )
        else
          ReportSection(
            title: top10
                ? '10 PRODUK TERATAS'
                : 'PRODUK TERJUAL (${_topProducts.length})',
            children: _topProducts.asMap().entries.map((e) {
              final p = e.value;
              return KvRow(
                '${e.key + 1}. ${p['name'] as String? ?? '-'}',
                CurrencyFormatter.format(
                  (p['revenue'] as num?)?.toDouble() ?? 0,
                ),
                subtitle:
                    '${p['qty'] ?? 0} terjual · ${p['category'] as String? ?? '-'}',
              );
            }).toList(),
          ),
      ],
    );
  }

  // ─── Void ────────────────────────────────────────────────────────────────────
  Widget _buildVoid() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Total Void',
                value: CurrencyFormatter.format(_voidTotal),
                accent: AppColors.error,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Jumlah Nota',
                value:
                    '${_voidOrders.map((order) => order['id']).toSet().length}',
                accent: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_voidOrders.isEmpty)
          const ReportEmpty(
            icon: Icons.block_outlined,
            message: 'Tidak ada void pada periode ini.',
          )
        else ...[
          for (var i = 0; i < _voidOrders.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _VoidOrderCard(order: _voidOrders[i]),
          ],
        ],
      ],
    );
  }

  // ─── Refund (order cancelled) ────────────────────────────────────────────────
  Widget _buildRefund() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Total Refund',
                value: CurrencyFormatter.format(_refundTotal),
                accent: AppColors.error,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Jumlah Nota',
                value: '${_refundOrders.length}',
                accent: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_refundOrders.isEmpty)
          const ReportEmpty(
            icon: Icons.assignment_return_outlined,
            message: 'Tidak ada refund pada periode ini.',
          )
        else ...[
          for (var i = 0; i < _refundOrders.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _RefundOrderCard(order: _refundOrders[i]),
          ],
        ],
      ],
    );
  }

  // ─── Kasir (Shift) ──────────────────────────────────────────────────────────
  // Net kas masuk/keluar (Selisih Bersih) untuk satu shift.
  double _shiftNet(String? shiftId) {
    double n = 0;
    for (final m in _movements) {
      if (m['shift_id'] == shiftId) {
        final a = (m['amount'] as num?)?.toDouble() ?? 0;
        n += m['type'] == 'in' ? a : -a;
      }
    }
    return n;
  }

  // ─── Kasir: kartu shift berjalan + riwayat buka/tutup (row → detail) ─────────
  Widget _buildKasir() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_isKasir)
          const ShiftActiveSection()
        else
          ManagementCashMovementSection(outletId: _outletId),
        const SizedBox(height: 24),
        _RepLabel('RIWAYAT 7 HARI TERAKHIR'),
        const SizedBox(height: 8),
        if (_shifts.isEmpty)
          const ReportEmpty(
            icon: Icons.badge_outlined,
            message: 'Belum ada shift pada periode ini.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _shifts.length; i++)
                  _ShiftRow(
                    shift: _shifts[i],
                    net: _shiftNet(_shifts[i]['id'] as String?),
                    isLast: i == _shifts.length - 1,
                    onTap: () => _showShiftDetail(_shifts[i]),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  void _showShiftDetail(Map<String, dynamic> s) {
    final shiftId = s['id'] as String?;
    final movs = _movements.where((m) => m['shift_id'] == shiftId).toList();
    final opening = (s['opening_cash'] as num?)?.toDouble() ?? 0;
    final closing = (s['closing_cash'] as num?)?.toDouble();
    final net = _shiftNet(shiftId);
    final start = DateTime.tryParse(s['start_time'] as String? ?? '');
    final end = DateTime.tryParse(s['end_time'] as String? ?? '');
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ShiftDetailSheet(
        start: start,
        end: end,
        opening: opening,
        closing: closing,
        net: net,
        movements: movs,
        showCashMovements: !_isKasir,
      ),
    );
  }

  // ─── Kas Kasir: rekap kas masuk/keluar (REKAP + DAFTAR) ──────────────────────
  Widget _buildKasKasir() {
    final k = _kasKasir;
    final movements = (k['movements'] as List?) ?? const [];
    final pemasukan = (k['pemasukan'] as num?)?.toDouble() ?? 0;
    final pengeluaran = (k['pengeluaran'] as num?)?.toDouble() ?? 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _RepLabel('REKAP KAS KASIR'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _RecapTile(
                label: 'Pemasukan',
                value: pemasukan,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _RecapTile(
                label: 'Pengeluaran',
                value: pengeluaran,
                color: AppColors.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _RepLabel('DAFTAR KAS KASIR'),
        const SizedBox(height: 8),
        if (movements.isEmpty)
          const ReportEmpty(
            icon: Icons.account_balance_wallet_outlined,
            message: 'Belum ada kas masuk/keluar pada periode ini.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < movements.length; i++)
                  _MovementTile(
                    Map<String, dynamic>.from(movements[i] as Map),
                    isLast: i == movements.length - 1,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  // ─── Jenis Bayar ─────────────────────────────────────────────────────────────
  Widget _buildJenisBayar() {
    final grandTotal = _payments.fold<double>(
      0,
      (s, e) => s + ((e['total'] as num?)?.toDouble() ?? 0),
    );
    final totalTx = _payments.fold<int>(
      0,
      (s, e) => s + ((e['count'] as num?)?.toInt() ?? 0),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Total Penerimaan',
                value: CurrencyFormatter.format(grandTotal),
                accent: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Total Transaksi',
                value: '$totalTx',
                accent: AppColors.info,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_payments.isEmpty)
          const ReportEmpty(
            icon: Icons.payments_outlined,
            message: 'Belum ada pembayaran pada periode ini.',
          )
        else
          ReportSection(
            title: 'RINCIAN METODE BAYAR (${_payments.length})',
            children: _payments.map((p) {
              final pct = (p['percentage'] as num?)?.toDouble() ?? 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (p['method'] as String? ?? '-').toUpperCase(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Text(
                          CurrencyFormatter.format(
                            (p['total'] as num?)?.toDouble() ?? 0,
                          ),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${pct.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${p['count'] ?? 0} transaksi',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct / 100,
                        backgroundColor: AppColors.surfaceVariant,
                        color: AppColors.primary,
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  Widget _statGrid(List<_CardItem> cards) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 560 ? 3 : 2);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: cols >= 4 ? 1.6 : 1.9,
          children: cards.map((c) => _StatCard(item: c)).toList(),
        );
      },
    );
  }
}

// ── Sidebar kategori (tablet/web) ─────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final List<int>? allowed;
  const _Sidebar({
    required this.selected,
    required this.onSelect,
    this.allowed,
  });

  // Grup → daftar index kategori (logika/index tidak diubah)
  static const _groups = <(String, List<int>)>[
    ('Penjualan', [0, 1, 5, 6]),
    ('Keuangan', [4, _refundIndex]),
    ('Operasional', [2, 3, _daftarOrderIndex]),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFEFEFEF), width: 0.5)),
      ),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Laporan',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Color(0xFF111111),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Penjualan toko Anda',
                  style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
                ),
              ],
            ),
          ),
          for (final g in _groups) ...[
            // Filter kategori sesuai izin (kasir hanya riwayat shift).
            if (g.$2.any((i) => allowed?.contains(i) ?? true)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 5),
                child: Text(
                  g.$1.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                    color: Color(0xFFBBBBBB),
                  ),
                ),
              ),
              for (final i in g.$2)
                if (allowed?.contains(i) ?? true)
                  _NavItem(
                    icon: _categories[i].$2,
                    label: _categories[i].$1,
                    active: selected == i,
                    onTap: () => onSelect(i),
                  ),
            ],
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE24B4A);
    return Material(
      color: active ? const Color(0xFFFFF5F5) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: active ? red : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Icon(
                  icon,
                  size: 14,
                  color: (active ? red : const Color(0xFF666666)).withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                    color: active ? red : const Color(0xFF666666),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Category chips (mobile) ───────────────────────────────────────────────────
class _CategoryChips extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final List<int>? allowed;
  const _CategoryChips({
    required this.selected,
    required this.onSelect,
    this.allowed,
  });

  @override
  Widget build(BuildContext context) {
    final items = allowed ?? List<int>.generate(_categories.length, (i) => i);
    return Container(
      color: Colors.white,
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: items.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final i = items[idx];
          final sel = selected == i;
          return ChoiceChip(
            label: Text(_categories[i].$1),
            selected: sel,
            onSelected: (_) => onSelect(i),
            labelStyle: TextStyle(
              fontSize: 12,
              color: sel ? Colors.white : AppColors.textSecondary,
              fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
            ),
            selectedColor: AppColors.primary,
            backgroundColor: AppColors.surfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide.none,
            ),
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

// ── Filter bar ────────────────────────────────────────────────────────────────
class _FilterBar extends StatelessWidget {
  final String period;
  final String label;
  final int offset;
  final bool loading;
  final ValueChanged<String> onPeriodChanged;
  final ValueChanged<int> onOffsetChanged;
  final VoidCallback onRefresh;
  final bool canNavigate;

  const _FilterBar({
    required this.period,
    required this.label,
    required this.offset,
    required this.loading,
    required this.onPeriodChanged,
    required this.onOffsetChanged,
    required this.onRefresh,
    this.canNavigate = true,
  });

  @override
  Widget build(BuildContext context) {
    const borderC = Color(0xFFE5E5E5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Period dropdown (32px)
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: borderC, width: 1.5),
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: period,
                isDense: true,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
                style: const TextStyle(fontSize: 12, color: Color(0xFF444444)),
                items: _periodLabel.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: (v) => v != null ? onPeriodChanged(v) : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // ‹
          _NavButton(
            icon: Icons.chevron_left,
            onTap: canNavigate ? () => onOffsetChanged(offset - 1) : null,
          ),
          const SizedBox(width: 8),
          // Date chip (28px)
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border.all(color: borderC, width: 1.5),
              borderRadius: BorderRadius.circular(6),
              color: Colors.white,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.calendar_today,
                  size: 11,
                  color: Color(0xFF999999),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF444444),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // ›
          _NavButton(
            icon: Icons.chevron_right,
            onTap: canNavigate && offset < 0
                ? () => onOffsetChanged(offset + 1)
                : null,
          ),

          // Refresh
          InkWell(
            onTap: loading ? null : onRefresh,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: borderC, width: 1.5),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  loading
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: Color(0xFF666666),
                          ),
                        )
                      : const Icon(
                          Icons.refresh,
                          size: 14,
                          color: Color(0xFF666666),
                        ),
                  const SizedBox(width: 4),
                  const Text(
                    'Refresh',
                    style: TextStyle(fontSize: 11, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _NavButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE5E5E5), width: 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 16,
            color: onTap != null
                ? const Color(0xFF666666)
                : const Color(0xFFCCCCCC),
          ),
        ),
      ),
    );
  }
}

// ── Stat card (redesigned) ────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final _CardItem item;
  const _StatCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Label (uppercase)
          Text(
            item.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
              color: Color(0xFFBBBBBB),
            ),
          ),
          const SizedBox(height: 6),
          // Value
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              item.value,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: item.muted
                    ? const Color(0xFF999999)
                    : const Color(0xFF111111),
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (item.subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              item.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xFFBBBBBB)),
            ),
          ],
          const Spacer(),
          // Accent bar
          Container(
            height: 2,
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              color: item.accent.withValues(alpha: item.accentOpacity),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Chart card ────────────────────────────────────────────────────────────────
class _ChartCard extends StatelessWidget {
  final List<Map<String, dynamic>> peakHours;
  const _ChartCard({required this.peakHours});

  @override
  Widget build(BuildContext context) {
    final maxY = peakHours.fold<double>(
      0,
      (m, e) => ((e['revenue'] as num?)?.toDouble() ?? 0) > m
          ? (e['revenue'] as num).toDouble()
          : m,
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
            child: Row(
              children: [
                const Text(
                  'Grafik Penjualan',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: Color(0xFF111111),
                  ),
                ),
                const Spacer(),
                // Toggle (Per Hari belum ada data → Per Jam aktif)
                Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF111111),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Per Jam',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Chart or empty
          if (maxY == 0) _emptyChart() else _chart(maxY),
        ],
      ),
    );
  }

  Widget _emptyChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          // Y axis stub labels
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 50,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: ['100rb', '80rb', '60rb', '40rb', '20rb', '0']
                      .map(
                        (l) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            l,
                            style: const TextStyle(
                              fontSize: 9,
                              color: AppColors.textDisabled,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    Icon(
                      Icons.assignment_outlined,
                      size: 48,
                      color: AppColors.primary.withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Belum ada penjualan',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Data akan muncul setelah ada transaksi',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Hour axis
          Padding(
            padding: const EdgeInsets.only(left: 50),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(12, (i) => i * 2)
                  .map(
                    (h) => Text(
                      '${h.toString().padLeft(2, '0')}:00',
                      style: const TextStyle(
                        fontSize: 9,
                        color: AppColors.textDisabled,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chart(double maxY) {
    final top = maxY * 1.15;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
      child: SizedBox(
        height: 160,
        child: BarChart(
          BarChartData(
            maxY: top,
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => const Color(0xFF111111),
                tooltipBorderRadius: BorderRadius.circular(6),
                tooltipPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                  CurrencyFormatter.format(rod.toY),
                  const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) =>
                  const FlLine(color: Color(0xFFF5F5F5), strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  getTitlesWidget: (v, _) {
                    if (v == 0) {
                      return const Text(
                        '0',
                        style: TextStyle(fontSize: 9, color: Color(0xFFCCCCCC)),
                      );
                    }
                    final label = v >= 1000000
                        ? '${(v / 1000000).toStringAsFixed(0)}jt'
                        : '${(v / 1000).toStringAsFixed(0)}rb';
                    return Text(
                      label,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFCCCCCC),
                      ),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 4,
                  getTitlesWidget: (v, _) {
                    final h = v.toInt();
                    if (h % 4 != 0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        h.toString().padLeft(2, '0'),
                        style: const TextStyle(
                          fontSize: 9,
                          color: Color(0xFFCCCCCC),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: peakHours.map((e) {
              final rev = (e['revenue'] as num?)?.toDouble() ?? 0;
              return BarChartGroupData(
                x: e['hour'] as int,
                barRods: [
                  BarChartRodData(
                    toY: rev,
                    color: const Color(
                      0xFFE24B4A,
                    ).withValues(alpha: rev > 0 ? 1.0 : 0.08),
                    width: 8,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                    backDrawRodData: BackgroundBarChartRodData(
                      show: true,
                      toY: top,
                      color: const Color(0xFFE24B4A).withValues(alpha: 0.08),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ── Metode Pembayaran card ────────────────────────────────────────────────────
class _MetodePembayaranCard extends StatelessWidget {
  final List<Map<String, dynamic>> payments;
  const _MetodePembayaranCard({required this.payments});

  static const _pieColors = [
    Color(0xFFE24B4A), // Cash
    Color(0xFFFCD34D), // Transfer
    Color(0xFF60A5FA), // QRIS
    Color(0xFFA78BFA), // Lainnya
    Color(0xFF34D399),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Metode Pembayaran',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: Color(0xFF111111),
            ),
          ),
          const SizedBox(height: 10),
          if (payments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Belum ada data',
                  style: TextStyle(color: AppColors.textDisabled, fontSize: 13),
                ),
              ),
            )
          else
            Row(
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 28,
                      sections: payments.asMap().entries.map((e) {
                        final pct =
                            (e.value['percentage'] as num?)?.toDouble() ?? 0;
                        return PieChartSectionData(
                          value: pct,
                          color: _pieColors[e.key % _pieColors.length],
                          radius: 18,
                          showTitle: false,
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: payments.asMap().entries.map((e) {
                      final p = e.value;
                      final color = _pieColors[e.key % _pieColors.length];
                      final pct = (p['percentage'] as num?)?.toDouble() ?? 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                p['method'] as String? ?? '-',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            Text(
                              CurrencyFormatter.format(
                                (p['total'] as num?)?.toDouble() ?? 0,
                              ),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '(${pct.toStringAsFixed(0)}%)',
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── Penjualan per Kategori card ───────────────────────────────────────────────
class _KategoriCard extends StatelessWidget {
  final List<Map<String, dynamic>> topProducts;
  const _KategoriCard({required this.topProducts});

  @override
  Widget build(BuildContext context) {
    // Agregasi revenue per kategori dari produk terjual
    final byCat = <String, double>{};
    for (final p in topProducts) {
      final cat = (p['category'] as String?)?.trim();
      final name = (cat == null || cat.isEmpty) ? 'Lainnya' : cat;
      byCat[name] =
          (byCat[name] ?? 0) + ((p['revenue'] as num?)?.toDouble() ?? 0);
    }
    final entries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = entries.isEmpty ? 0.0 : entries.first.value;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Penjualan per Kategori',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: Color(0xFF111111),
            ),
          ),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Belum ada data kategori',
                  style: TextStyle(fontSize: 12, color: AppColors.textDisabled),
                ),
              ),
            )
          else
            for (var i = 0; i < entries.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  border: i < entries.length - 1
                      ? const Border(
                          bottom: BorderSide(
                            color: Color(0xFFF5F5F5),
                            width: 0.5,
                          ),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entries[i].key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF555555),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 60,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F0F0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: maxVal > 0 ? entries[i].value / maxVal : 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFE24B4A),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: Text(
                        CurrencyFormatter.format(entries[i].value),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF111111),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

// ── Void order card ───────────────────────────────────────────────────────────
class _VoidOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  const _VoidOrderCard({required this.order});

  static const _typeLabel = {
    'dine_in': 'Dine In',
    'takeaway': 'Takeaway',
    'self_order': 'Self Order',
  };

  @override
  Widget build(BuildContext context) {
    final typeLabel =
        _typeLabel[order['order_type']] ?? (order['order_type'] ?? '-');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          title: Text(
            order['order_number'] as String? ?? '-',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              typeLabel,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          trailing: Text(
            CurrencyFormatter.format(
              (order['void_amount'] as num?)?.toDouble() ?? 0,
            ),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.error,
              fontSize: 13,
            ),
          ),
          children: [
            if (order['product_name'] != null)
              _row('Produk', order['product_name'] as String),
            if ((order['quantity'] as num?) != null)
              _row('Jumlah', '${(order['quantity'] as num).toInt()}'),
            _row('Tgl Void', _fmtDateTime(order['voided_at'] as String?)),
            _row('Tgl Order', _fmtDateTime(order['created_at'] as String?)),
            _row('Kasir', order['kasir_name'] as String? ?? '-'),
            _row('Otorisasi', order['otorisasi_name'] as String? ?? '-'),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ── Refund order card ─────────────────────────────────────────────────────────
class _RefundOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  const _RefundOrderCard({required this.order});

  static const _typeLabel = {
    'dine_in': 'Dine In',
    'takeaway': 'Takeaway',
    'self_order': 'Self Order',
  };

  @override
  Widget build(BuildContext context) {
    final typeLabel =
        _typeLabel[order['order_type']] ?? (order['order_type'] ?? '-');
    final reason = order['cancel_reason'] as String?;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          title: Text(
            order['order_number'] as String? ?? '-',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              typeLabel,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          trailing: Text(
            CurrencyFormatter.format(
              (order['total_amount'] as num?)?.toDouble() ?? 0,
            ),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.error,
              fontSize: 13,
            ),
          ),
          children: [
            _row('Tgl Refund', _fmtDateTime(order['cancelled_at'] as String?)),
            _row('Tgl Order', _fmtDateTime(order['created_at'] as String?)),
            _row('Kasir', order['kasir_name'] as String? ?? '-'),
            _row('Otorisasi', order['otorisasi_name'] as String? ?? '-'),
            if (reason != null && reason.isNotEmpty) _row('Alasan', reason),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Kasir shift card ──────────────────────────────────────────────────────────
// ── Label section (REKAP KAS KASIR / RIWAYAT SHIFT / DAFTAR) ─────────────────
class _RepLabel extends StatelessWidget {
  final String text;
  const _RepLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
      color: AppColors.textSecondary,
    ),
  );
}

// ── Baris shift (Kasir): tgl · jam → Selisih Bersih pill ────────────────────
class _ShiftRow extends StatelessWidget {
  final Map<String, dynamic> shift;
  final double net;
  final bool isLast;
  final VoidCallback onTap;
  const _ShiftRow({
    required this.shift,
    required this.net,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = DateTime.tryParse(shift['start_time'] as String? ?? '');
    final end = DateTime.tryParse(shift['end_time'] as String? ?? '');
    final date = start != null
        ? DateFormat('d MMM', 'id_ID').format(start.toLocal())
        : '—';
    final range = start != null
        ? '${DateFormat('HH:mm').format(start.toLocal())} – '
              '${end != null ? DateFormat('HH:mm').format(end.toLocal()) : 'aktif'}'
        : '—';
    final color = net < 0 ? AppColors.error : AppColors.success;
    final label = (net >= 0 ? '+' : '−') + CurrencyFormatter.format(net.abs());
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : const Border(
                  bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
                ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(
                date,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                range,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13.5,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Detail shift (bottom sheet): kas awal/akhir + transaksi + selisih ───────
class _ShiftDetailSheet extends StatelessWidget {
  final DateTime? start;
  final DateTime? end;
  final double opening;
  final double? closing;
  final double net;
  final List<Map<String, dynamic>> movements;
  final bool showCashMovements;
  const _ShiftDetailSheet({
    required this.start,
    required this.end,
    required this.opening,
    required this.closing,
    required this.net,
    required this.movements,
    required this.showCashMovements,
  });

  @override
  Widget build(BuildContext context) {
    String dur() {
      if (start == null) return '—';
      final e = end ?? DateTime.now();
      final d = e.difference(start!);
      final h = d.inHours, m = d.inMinutes % 60;
      return h > 0 ? '${h}j ${m}m' : '${m}m';
    }

    final header = start != null
        ? '${DateFormat('d MMM', 'id_ID').format(start!.toLocal())} · '
              '${DateFormat('HH:mm').format(start!.toLocal())} – '
              '${end != null ? DateFormat('HH:mm').format(end!.toLocal()) : 'aktif'}'
        : 'Detail Shift';
    final netColor = net < 0 ? AppColors.error : AppColors.success;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header gelap
          Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DETAIL SHIFT',
                        style: TextStyle(
                          color: Color(0xFF9A9A9A),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        header,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Ringkasan kas
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: _kv('DURASI', dur())),
                Expanded(
                  child: _kv('KAS AWAL', CurrencyFormatter.format(opening)),
                ),
                Expanded(
                  child: _kv(
                    'KAS AKHIR',
                    closing != null ? CurrencyFormatter.format(closing!) : '—',
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (showCashMovements) ...[
            // Transaksi kas
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _RepLabel('TRANSAKSI'),
              ),
            ),
            if (movements.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Tak ada kas masuk/keluar di shift ini.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ...movements.map(
                (m) => _MovementTile(m, isLast: true, dense: true),
              ),
            Container(
              color: const Color(0xFFF8FAFC),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Selisih Bersih',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  Text(
                    (net >= 0 ? '+' : '−') +
                        CurrencyFormatter.format(net.abs()),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: netColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ],
  );
}

// ── Tile kas masuk/keluar (Kas Kasir & detail shift) ────────────────────────
class _RecapTile extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const _RecapTile({
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          CurrencyFormatter.format(value),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    ),
  );
}

class _MovementTile extends StatelessWidget {
  final Map<String, dynamic> m;
  final bool isLast;
  final bool dense;
  const _MovementTile(this.m, {required this.isLast, this.dense = false});
  @override
  Widget build(BuildContext context) {
    final isIn = m['type'] == 'in';
    final amt = (m['amount'] as num?)?.toDouble() ?? 0;
    final note = (m['note'] as String?)?.isNotEmpty == true
        ? m['note'] as String
        : (isIn ? 'Uang Masuk' : 'Uang Keluar');
    final t = DateTime.tryParse(m['created_at'] as String? ?? '');
    final time = t != null ? DateFormat('HH:mm').format(t.toLocal()) : '';
    final color = isIn ? AppColors.success : AppColors.error;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 10 : 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
              ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isIn ? Icons.add : Icons.remove,
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isIn ? 'Kas Masuk' : 'Kas Keluar',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  time.isNotEmpty ? '$time · $note' : note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            (isIn ? '+' : '−') + CurrencyFormatter.format(amt),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDateTime(String? iso) {
  if (iso == null) return '-';
  final d = DateTime.parse(iso).toLocal();
  return DateFormat('d MMM yyyy, HH:mm', 'id_ID').format(d);
}

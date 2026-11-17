import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../../../features/pos/presentation/pages/kasir_shell.dart';
import '../../../../features/pos/presentation/widgets/print_target_sheet.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/order.dart';
import '../../data/datasources/orders_datasource.dart';
import '../widgets/partial_refund_dialog.dart';
import '../widgets/void_order_dialog.dart';

class PenjualanPage extends StatefulWidget {
  const PenjualanPage({super.key});

  @override
  State<PenjualanPage> createState() => _PenjualanPageState();
}

class _PenjualanPageState extends State<PenjualanPage> {
  static const _pageSize = 50;

  final _ds = OrdersDatasource();
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  List<Order> _sales = [];
  Map<String, String> _cashiers = {};
  Map<String, double> _netAmounts = {};
  Map<String, DateTime> _salesAt = {};
  Map<String, SalesDaySummary> _daySummaries = {};
  double _totalSales = 0;
  int _totalTransactions = 0;
  double _averageSales = 0;
  Timer? _searchDebounce;
  int _requestSerial = 0;

  // ── Filter state ──────────────────────────────────────────────────────────
  String _selectedJenis = 'semua'; // semua | dinein | takeaway | online
  String _searchQuery = '';
  DateTimeRange? _dateRange; // null = semua tanggal

  // ── Format tanggal (id_ID sudah di-init di main) ──────────────────────────
  final _dfSubtitle = DateFormat('dd MMM yyyy', 'id_ID');
  final _dfGroup = DateFormat('dd MMMM yyyy', 'id_ID');
  final _dfShort = DateFormat('dd MMM', 'id_ID');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    if (append && (_loading || _loadingMore || !_hasMore)) return;
    final requestId = ++_requestSerial;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final auth = context.read<AuthBloc>().state;
      final outletId = auth is AuthAuthenticated
          ? auth.profile.outletId ?? ''
          : '';
      if (outletId.isEmpty) {
        throw Exception('Akun belum terhubung ke outlet');
      }
      final profile = auth is AuthAuthenticated ? auth.profile : null;
      final range = _dateRange;
      final result = await _ds.fetchSalesPage(
        outletId,
        createdBy: profile?.role.value == 'kasir' ? profile!.id : null,
        kind: _selectedJenis,
        dateFrom: range == null ? null : DateUtils.dateOnly(range.start),
        dateTo: range == null
            ? null
            : DateUtils.dateOnly(range.end).add(const Duration(days: 1)),
        search: _searchQuery,
        offset: append ? _sales.length : 0,
        limit: _pageSize,
      );
      if (!mounted || requestId != _requestSerial) return;
      setState(() {
        _sales = append ? [..._sales, ...result.orders] : result.orders;
        _cashiers = append
            ? {..._cashiers, ...result.cashiers}
            : result.cashiers;
        _netAmounts = append
            ? {..._netAmounts, ...result.netAmounts}
            : result.netAmounts;
        _salesAt = append ? {..._salesAt, ...result.salesAt} : result.salesAt;
        _daySummaries = result.days;
        _totalSales = result.totalSales;
        _totalTransactions = result.totalTransactions;
        _averageSales = result.averageSales;
        _hasMore = result.hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestSerial) return;
      setState(() {
        if (!append) {
          _error = humanizeError(e, fallback: 'Gagal memuat penjualan.');
        }
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// Server sudah menerapkan seluruh filter dan mengurutkan terbaru dulu.
  List<Order> get _visible {
    final list = List<Order>.of(_sales);
    list.sort((a, b) => _saleTime(b).compareTo(_saleTime(a)));
    return list;
  }

  DateTime _saleTime(Order order) => _salesAt[order.id] ?? order.createdAt;

  double _netAmount(Order order) => _netAmounts[order.id] ?? order.totalAmount;

  String get _periodLabel {
    final range = _dateRange;
    if (range == null) return 'Semua tanggal';
    if (DateUtils.isSameDay(range.start, range.end)) {
      return _dfSubtitle.format(range.start);
    }
    return '${_dfSubtitle.format(range.start)} – '
        '${_dfSubtitle.format(range.end)}';
  }

  void _selectJenis(String value) {
    if (_selectedJenis == value) return;
    setState(() => _selectedJenis = value);
    _load();
  }

  void _onSearchChanged(String value) {
    _searchQuery = value;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () => _load());
  }

  // ── Filter tanggal (popup) ────────────────────────────────────────────────
  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = DateUtils.dateOnly(now);

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.slate300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Filter Tanggal',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
            _dateOption(sheetCtx, 'Semua tanggal', null),
            _dateOption(
              sheetCtx,
              'Hari ini',
              DateTimeRange(start: today, end: today),
            ),
            _dateOption(
              sheetCtx,
              'Kemarin',
              DateTimeRange(
                start: today.subtract(const Duration(days: 1)),
                end: today.subtract(const Duration(days: 1)),
              ),
            ),
            _dateOption(
              sheetCtx,
              '7 hari terakhir',
              DateTimeRange(
                start: today.subtract(const Duration(days: 6)),
                end: today,
              ),
            ),
            _dateOption(
              sheetCtx,
              '30 hari terakhir',
              DateTimeRange(
                start: today.subtract(const Duration(days: 29)),
                end: today,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.event_outlined, size: 20),
              title: const Text(
                'Pilih tanggal…',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(now.year - 2),
                  lastDate: now,
                  initialDateRange: _dateRange,
                );
                if (picked != null && mounted) {
                  setState(() => _dateRange = picked);
                  _load();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _dateOption(
    BuildContext sheetCtx,
    String label,
    DateTimeRange? range,
  ) {
    final selected = _isSameRange(_dateRange, range);
    return ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: selected
          ? const Icon(Icons.check, size: 18, color: AppColors.salesAccentRed)
          : null,
      onTap: () {
        setState(() => _dateRange = range);
        Navigator.pop(sheetCtx);
        _load();
      },
    );
  }

  bool _isSameRange(DateTimeRange? a, DateTimeRange? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return DateUtils.isSameDay(a.start, b.start) &&
        DateUtils.isSameDay(a.end, b.end);
  }

  // ── Detail / refund (popup yang sudah ada) ────────────────────────────────
  Future<void> _openRefund(Order order) async {
    if (!mounted) return;
    final ok = await showRefundOrderDialog(context, order: order);
    if (ok && mounted) _load();
  }

  Future<void> _openPartialRefund(Order order) async {
    if (!mounted) return;
    final ok = await showPartialRefundDialog(context, order: order);
    if (ok && mounted) _load();
  }

  Future<void> _openSaleActions(Order order) async {
    final originalCashier =
        _cashiers[order.createdBy] ??
        (context.read<AuthBloc>().state is AuthAuthenticated
            ? (context.read<AuthBloc>().state as AuthAuthenticated)
                  .profile
                  .fullName
            : '-');
    final action = await showModalBottomSheet<_SaleAction>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _SaleActionsSheet(
        order: order,
        cashierName: originalCashier,
        salesAt: _saleTime(order),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SaleAction.printReceipt:
        await showPrintTargetSheet(
          context,
          orderId: order.id,
          outletId: order.outletId,
          cashierName: originalCashier,
          orderSnapshot: order,
        );
      case _SaleAction.refund:
        await _openRefund(order);
      case _SaleAction.partialRefund:
        await _openPartialRefund(order);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.salesCanvas,
      appBar: _buildTopbar(),
      body: _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : LayoutBuilder(
              builder: (context, c) {
                // Lebar (tablet): sidebar samping. Sempit (HP): sidebar di atas.
                if (c.maxWidth >= 700) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 220, child: _buildSidebar()),
                      Expanded(child: _buildTable()),
                    ],
                  );
                }
                return Column(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 210),
                      child: _buildSidebar(),
                    ),
                    const Divider(height: 1),
                    Expanded(child: _buildTable()),
                  ],
                );
              },
            ),
    );
  }

  // ── Topbar ────────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildTopbar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 0,
      leadingWidth: 44,
      leading: IconButton(
        icon: const Icon(Icons.menu, size: 20, color: AppColors.salesTextDark),
        onPressed: KasirShell.openMenu,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Penjualan',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.salesTextDark,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              _periodLabel,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.salesTextLight,
              ),
            ),
          ),
        ],
      ),
      actions: [
        // Tombol filter tanggal
        GestureDetector(
          onTap: _pickDateRange,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.salesChipBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 12,
                  color: AppColors.salesTextGray,
                ),
                SizedBox(width: 4),
                Text(
                  'Filter',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.salesTextGray,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Tombol refresh
        GestureDetector(
          onTap: _loading ? null : _load,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.salesChipBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.salesTextGray,
                    ),
                  )
                : const Icon(
                    Icons.refresh,
                    size: 14,
                    color: AppColors.salesTextGray,
                  ),
          ),
        ),
        const SizedBox(width: 14),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(0.5),
        child: Divider(
          height: 0.5,
          thickness: 0.5,
          color: AppColors.salesTopbarBorder,
        ),
      ),
    );
  }

  // ── Sidebar kiri ──────────────────────────────────────────────────────────
  Widget _buildSidebar() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: AppColors.salesTopbarBorder, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatBox(
              bg: AppColors.salesBoxSalesBg,
              label: 'PENJUALAN BERSIH',
              labelColor: AppColors.salesBoxSalesLabel,
              value: CurrencyFormatter.format(_totalSales),
            ),
            const SizedBox(height: 10),
            _StatBox(
              bg: AppColors.salesBoxTrxBg,
              label: 'TRANSAKSI',
              labelColor: AppColors.salesBoxTrxLabel,
              value: '$_totalTransactions',
            ),
            const SizedBox(height: 10),
            _StatBox(
              bg: AppColors.salesBoxAvgBg,
              label: 'RATA-RATA / TRX',
              labelColor: AppColors.salesBoxAvgLabel,
              value: CurrencyFormatter.format(_averageSales),
            ),
            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(vertical: 10),
              color: AppColors.salesGroupDivider,
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'FILTER JENIS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppColors.salesTextFaint,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            _JenisItem(
              label: 'Semua',
              active: _selectedJenis == 'semua',
              activeBg: AppColors.salesAccentRed,
              activeFg: Colors.white,
              onTap: () => _selectJenis('semua'),
            ),
            const SizedBox(height: 6),
            _JenisItem(
              label: 'Dine In',
              icon: Icons.chair_outlined,
              active: _selectedJenis == 'dinein',
              activeBg: AppColors.salesDineInBg,
              activeFg: AppColors.salesDineInFg,
              onTap: () => _selectJenis('dinein'),
            ),
            const SizedBox(height: 6),
            _JenisItem(
              label: 'Online',
              icon: Icons.qr_code,
              active: _selectedJenis == 'online',
              activeBg: AppColors.salesOnlineBg,
              activeFg: AppColors.salesOnlineFg,
              onTap: () => _selectJenis('online'),
            ),
            const SizedBox(height: 6),
            _JenisItem(
              label: 'Takeaway',
              icon: Icons.storefront_outlined,
              active: _selectedJenis == 'takeaway',
              activeBg: AppColors.salesKasirBg,
              activeFg: AppColors.salesKasirFg,
              onTap: () => _selectJenis('takeaway'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Kolom kanan: search + header + list ───────────────────────────────────
  Widget _buildTable() {
    return Column(
      children: [
        // Search bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(
                color: AppColors.salesTopbarBorder,
                width: 0.5,
              ),
            ),
          ),
          child: SizedBox(
            height: 36,
            child: TextField(
              onChanged: _onSearchChanged,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.salesTextMid,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppColors.salesChipBg,
                hintText: 'Cari nama / no transaksi...',
                hintStyle: const TextStyle(
                  fontSize: 11,
                  color: AppColors.salesTextFainter,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 15,
                  color: AppColors.salesTextFaint,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        // Header tabel
        const _TableHeaderRow(),
        // List
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildList(),
        ),
      ],
    );
  }

  Widget _buildList() {
    final visible = _visible;
    if (visible.isEmpty) {
      return const _EmptySales();
    }

    // Group per tanggal (visible sudah terurut terbaru dulu).
    final groups = <DateTime, List<Order>>{};
    for (final o in visible) {
      final key = DateUtils.dateOnly(_saleTime(o).toLocal());
      (groups[key] ??= []).add(o);
    }

    final children = <Widget>[];
    var rowIndex = 0;
    groups.forEach((day, orders) {
      final dayKey = DateFormat('yyyy-MM-dd').format(day);
      final summary = _daySummaries[dayKey];
      final dayTotal =
          summary?.total ??
          orders.fold<double>(0, (sum, order) => sum + _netAmount(order));
      children.add(
        _DateGroupHeader(
          label: _dfGroup.format(day).toUpperCase(),
          total: CurrencyFormatter.format(dayTotal),
          count: summary?.count ?? orders.length,
        ),
      );
      for (final o in orders) {
        children.add(
          _TransactionRow(
            order: o,
            salesAt: _saleTime(o),
            amount: _netAmount(o),
            cashier: _cashiers[o.createdBy] ?? '-',
            even: rowIndex.isEven,
            shortDate: _dfShort.format(_saleTime(o).toLocal()),
            onTap: () => _openSaleActions(o),
          ),
        );
        rowIndex++;
      }
    });
    if (_hasMore) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: OutlinedButton.icon(
            onPressed: _loadingMore ? null : () => _load(append: true),
            icon: _loadingMore
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more, size: 18),
            label: Text(_loadingMore ? 'Memuat…' : 'Muat transaksi berikutnya'),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: children),
    );
  }
}

enum _SaleAction { printReceipt, partialRefund, refund }

@visibleForTesting
Widget saleActionsSheetForTesting({
  required Order order,
  required String cashierName,
  DateTime? salesAt,
}) =>
    _SaleActionsSheet(order: order, cashierName: cashierName, salesAt: salesAt);

class _SaleActionsSheet extends StatelessWidget {
  final Order order;
  final String cashierName;
  final DateTime? salesAt;

  const _SaleActionsSheet({
    required this.order,
    required this.cashierName,
    this.salesAt,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateFormat(
      'dd MMM yyyy, HH:mm',
      'id_ID',
    ).format((salesAt ?? order.createdAt).toLocal());
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.slate300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.salesBoxSalesBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.receipt_long_outlined,
                    color: AppColors.salesAccentRed,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Transaksi #${order.orderNumber}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.salesTextDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        date,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.salesTextLight,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Tutup',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.salesChipBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _saleDetailRow(
                    'Pelanggan',
                    order.customerName ?? 'Tanpa Pelanggan',
                  ),
                  const SizedBox(height: 9),
                  _saleDetailRow('Kasir', cashierName),
                  const SizedBox(height: 9),
                  _saleDetailRow(
                    'Total',
                    CurrencyFormatter.format(order.totalAmount),
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton.icon(
                key: const Key('sale-reprint-receipt'),
                onPressed: () =>
                    Navigator.pop(context, _SaleAction.printReceipt),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.salesAccentRed,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text(
                  'Cetak Ulang Struk',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                key: const Key('sale-partial-refund'),
                onPressed: () =>
                    Navigator.pop(context, _SaleAction.partialRefund),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.salesAccentRed,
                  side: BorderSide(
                    color: AppColors.salesAccentRed.withValues(alpha: 0.35),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.rule, size: 17),
                label: const Text('Refund Sebagian'),
              ),
            ),
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, _SaleAction.refund),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: BorderSide(
                    color: AppColors.error.withValues(alpha: 0.35),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.undo_outlined, size: 17),
                label: const Text('Refund Transaksi'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _saleDetailRow(String label, String value, {bool bold = false}) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.salesTextLight),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: AppColors.salesTextDark,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Lebar kolom tabel (shared header & row) ───────────────────────────────────
Widget _tableCols({
  required Widget name,
  required Widget no,
  required Widget tgl,
  required Widget kasir,
  required Widget bayar,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: name),
      const SizedBox(width: 8),
      SizedBox(width: 65, child: no),
      const SizedBox(width: 8),
      SizedBox(width: 85, child: tgl),
      const SizedBox(width: 8),
      SizedBox(width: 60, child: kasir),
      const SizedBox(width: 8),
      SizedBox(width: 100, child: bayar),
    ],
  );
}

const _headerStyle = TextStyle(
  fontSize: 10,
  fontWeight: FontWeight.w500,
  color: AppColors.salesTextFaint,
  letterSpacing: 0.4,
);

// ── Stat box ──────────────────────────────────────────────────────────────────
class _StatBox extends StatelessWidget {
  final Color bg;
  final String label;
  final Color labelColor;
  final String value;
  const _StatBox({
    required this.bg,
    required this.label,
    required this.labelColor,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: labelColor,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 3),
          SizedBox(
            height: 21,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.salesTextDark,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Item filter jenis ─────────────────────────────────────────────────────────
class _JenisItem extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final Color activeBg;
  final Color activeFg;
  final VoidCallback onTap;
  const _JenisItem({
    required this.label,
    required this.active,
    required this.activeBg,
    required this.activeFg,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeFg : AppColors.salesTextMuted;
    // "Semua" tidak aktif → teks #666; lainnya tidak aktif → #888.
    final inactiveFg = icon == null
        ? AppColors.salesTextGray
        : AppColors.salesTextMuted;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: active ? activeFg : inactiveFg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: active ? fg : inactiveFg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header tabel ──────────────────────────────────────────────────────────────
class _TableHeaderRow extends StatelessWidget {
  const _TableHeaderRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(
        color: AppColors.salesHeaderBg,
        border: Border(
          bottom: BorderSide(color: AppColors.salesGroupDivider, width: 0.5),
        ),
      ),
      child: _tableCols(
        name: const Text('NAMA', style: _headerStyle),
        no: const Text('NO', style: _headerStyle),
        tgl: const Text('TGL & JAM', style: _headerStyle),
        kasir: const Text('KASIR', style: _headerStyle),
        bayar: const Text(
          'BAYAR',
          style: _headerStyle,
          textAlign: TextAlign.right,
        ),
      ),
    );
  }
}

// ── Date group header ─────────────────────────────────────────────────────────
class _DateGroupHeader extends StatelessWidget {
  final String label;
  final String total;
  final int count;
  const _DateGroupHeader({
    required this.label,
    required this.total,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.salesCanvas,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.salesTextFaint,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$total · $count trx',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.salesAccentRed,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Row transaksi ─────────────────────────────────────────────────────────────
class _TransactionRow extends StatelessWidget {
  final Order order;
  final DateTime salesAt;
  final double amount;
  final String cashier;
  final bool even;
  final String shortDate;
  final VoidCallback onTap;
  const _TransactionRow({
    required this.order,
    required this.salesAt,
    required this.amount,
    required this.cashier,
    required this.even,
    required this.shortDate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badge = _badgeFor(order.orderType);
    final time = DateFormat('HH:mm').format(salesAt.toLocal());

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: even ? AppColors.salesRowAlt : Colors.white,
          border: const Border(
            bottom: BorderSide(color: AppColors.salesRowDivider, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: _tableCols(
          name: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                order.customerName ?? 'Tanpa Pelanggan',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.salesTextMid,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _JenisBadge(badge: badge),
              ),
            ],
          ),
          no: Text(
            '#${order.orderNumber}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.salesTextLight,
            ),
          ),
          tgl: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                time,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.salesTextMid,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  shortDate,
                  style: const TextStyle(
                    fontSize: 9,
                    color: AppColors.salesTextFaint,
                  ),
                ),
              ),
            ],
          ),
          kasir: Text(
            cashier,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.salesTextLight,
            ),
          ),
          bayar: Text(
            CurrencyFormatter.format(amount),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.salesTextDark,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Badge jenis order ─────────────────────────────────────────────────────────
class _BadgeStyle {
  final String label;
  final Color bg;
  final Color fg;
  const _BadgeStyle(this.label, this.bg, this.fg);
}

_BadgeStyle _badgeFor(OrderType type) => switch (type) {
  OrderType.dineIn => const _BadgeStyle(
    'Dine In',
    AppColors.salesDineInBg,
    AppColors.salesDineInFg,
  ),
  OrderType.selfOrder => const _BadgeStyle(
    'Online',
    AppColors.salesOnlineBg,
    AppColors.salesOnlineFg,
  ),
  OrderType.takeaway => const _BadgeStyle(
    'Takeaway',
    AppColors.salesKasirBg,
    AppColors.salesKasirFg,
  ),
};

class _JenisBadge extends StatelessWidget {
  final _BadgeStyle badge;
  const _JenisBadge({required this.badge});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badge.bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        badge.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: badge.fg,
        ),
      ),
    );
  }
}

// ── Empty & error ─────────────────────────────────────────────────────────────
class _EmptySales extends StatelessWidget {
  const _EmptySales();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 80),
        Icon(
          Icons.point_of_sale_outlined,
          size: 56,
          color: AppColors.textDisabled,
        ),
        SizedBox(height: 12),
        Center(
          child: Text(
            'Tidak ada transaksi',
            style: TextStyle(color: AppColors.salesTextLight, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Coba lagi')),
        ],
      ),
    );
  }
}

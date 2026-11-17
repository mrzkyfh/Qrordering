import 'dart:async';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show PaperSize;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_skeleton.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../core/widgets/app_search_field.dart';
import '../../../../constants/colors.dart';
import '../../../../shared/widgets/badge_label.dart';
import '../../../../shared/widgets/payment_success_dialog.dart';
import '../../../../shared/widgets/order_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../bloc/orders_bloc.dart';
import '../widgets/void_order_dialog.dart';
import '../widgets/item_void_dialog.dart';
import '../widgets/kitchen_item_print_dialog.dart';
import '../widgets/partial_refund_dialog.dart';
import '../../../../shared/services/receipt_pdf.dart';
import '../../../../shared/widgets/receipt_preview.dart';
import '../../../pos/presentation/widgets/till_resolver.dart';
import '../../../../features/pos/presentation/bloc/pos_bloc.dart';
import '../../../../features/pos/presentation/bloc/shift_bloc.dart';
import '../../../../features/pos/data/datasources/pos_datasource.dart';
import '../../../../features/pos/domain/entities/cart_item.dart';
import '../../../../features/pos/domain/entities/selected_extra.dart';
import '../../../../shared/services/offline_queue_service.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/sync_service.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../../../shared/services/error_log_service.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/receipt_builder.dart';
import '../../../pos/presentation/widgets/print_target_sheet.dart';
import '../../../../shared/widgets/printer_connect_dialog.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/thousands_formatter.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../../../features/pos/presentation/pages/kasir_shell.dart';
import '../../data/datasources/orders_datasource.dart';

Future<Set<String>> _loadEnabledPaymentMethods(String outletId) async {
  const all = {'cash', 'qris', 'debit', 'credit', 'ewallet', 'transfer'};
  Set<String> fromSettings(Map<String, dynamic> settings) {
    final raw = settings['payment_methods'];
    if (raw is! List) return all;
    final active = raw.map((e) => e.toString()).where(all.contains).toSet();
    active.add('cash');
    return active;
  }

  final datasource = PosDatasource();
  if (!ConnectivityService.instance.online.value) {
    final cached = datasource.cachedOutletSettings(outletId);
    return cached == null ? all : fromSettings(cached);
  }
  try {
    return fromSettings(await datasource.fetchOutletSettings(outletId));
  } catch (_) {
    final cached = datasource.cachedOutletSettings(outletId);
    return cached == null ? all : fromSettings(cached);
  }
}

String? _currentStaffName(BuildContext context) {
  try {
    final auth = context.read<AuthBloc>().state;
    return auth is AuthAuthenticated ? auth.profile.fullName : null;
  } catch (_) {
    // OrderListPage dapat dipasang tanpa AuthBloc pada widget test.
    return null;
  }
}

/// Halaman utama "Daftar Order" — tampilan kartu (grid) seperti POS modern.
class OrderListPage extends StatelessWidget {
  /// Injeksi bloc (untuk widget test). Produksi: null → buat & load sendiri.
  final OrdersBloc? bloc;
  const OrderListPage({super.key, this.bloc});

  @override
  Widget build(BuildContext context) {
    if (bloc != null) {
      return BlocProvider.value(value: bloc!, child: const _OrderCardsView());
    }
    final authState = context.read<AuthBloc>().state;
    final outletId = authState is AuthAuthenticated
        ? authState.profile.outletId ?? ''
        : '';
    return BlocProvider(
      create: (_) =>
          OrdersBloc(datasource: OrdersDatasource())
            ..add(OrdersLoadRequested(outletId)),
      child: const _OrderCardsView(),
    );
  }
}

/// Tampilan tabel lama — dipakai di halaman Laporan (sub-bagian "Daftar Order").
class OrderTablePage extends StatelessWidget {
  const OrderTablePage({super.key});

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthBloc>().state;
    final outletId = authState is AuthAuthenticated
        ? authState.profile.outletId ?? ''
        : '';
    return BlocProvider(
      create: (_) =>
          OrdersBloc(datasource: OrdersDatasource())
            ..add(OrdersLoadRequested(outletId)),
      child: const _OrderListView(embedded: true),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Tampilan KARTU (grid) — halaman utama Daftar Order
// ════════════════════════════════════════════════════════════════════════════

enum _OrderTab { all, online, process, done }

extension _OrderTabX on _OrderTab {
  String get label => switch (this) {
    _OrderTab.all => 'Semua',
    _OrderTab.online => 'Order Online',
    _OrderTab.process => 'Kasir',
    _OrderTab.done => 'Selesai',
  };

  bool match(Order o) => switch (this) {
    _OrderTab.all => true,
    _OrderTab.online => o.orderType == OrderType.selfOrder,
    _OrderTab.process =>
      !o.isFullyPaid &&
          (o.status == OrderStatus.draft ||
              o.status == OrderStatus.confirmed ||
              o.status == OrderStatus.preparing ||
              o.status == OrderStatus.ready),
    _OrderTab.done =>
      o.isFullyPaid ||
          o.status == OrderStatus.served ||
          o.status == OrderStatus.paid ||
          o.status == OrderStatus.cancelled,
  };
}

class _OrderCardsView extends StatefulWidget {
  const _OrderCardsView();

  @override
  State<_OrderCardsView> createState() => _OrderCardsViewState();
}

class _OrderCardsViewState extends State<_OrderCardsView> {
  _OrderTab _tab = _OrderTab.all;
  String _query = '';

  // Memoisasi hasil sort: sort O(n log n) TIDAK boleh jalan tiap keystroke
  // pencarian (yang cuma memicu setState _query). Hanya re-sort saat data order
  // benar-benar berubah (identitas list state / jumlah draf offline berubah).
  List<Order>? _sortedCache;
  List<Order>? _lastActive;
  List<Order>? _lastCompleted;
  int _lastOfflineLen = -1;

  List<Order> _allSorted(OrdersState s) {
    final offlineLen = OfflineQueueService.instance.pendingCount.value;
    if (_sortedCache != null &&
        identical(s.activeOrders, _lastActive) &&
        identical(s.completedOrders, _lastCompleted) &&
        offlineLen == _lastOfflineLen) {
      return _sortedCache!;
    }

    final now = DateTime.now();
    // createdAt di-parse sebagai UTC → konversi ke waktu lokal sebelum
    // membandingkan tanggal, agar order dini hari (WIB) tidak salah tersembunyi.
    bool isToday(DateTime d) {
      final l = d.toLocal();
      return l.year == now.year && l.month == now.month && l.day == now.day;
    }

    // Tampilkan: semua transaksi HARI INI (semua status) + SEMUA order yang
    // masih aktif (belum lunas/batal/void) walau dibuat kemarin — agar order
    // yang belum selesai tidak "hilang" dari pandangan kasir + draf offline.
    final queued = _offlineOrders(s.outletId);
    final queuedIds = queued.map((order) => order.id).toSet();
    final list =
        [
              ...queued,
              ...s.activeOrders.where((order) => !queuedIds.contains(order.id)),
              ...s.completedOrders.where(
                (order) => !queuedIds.contains(order.id),
              ),
            ]
            // Order void adalah histori audit dan hanya ditampilkan pada
            // Laporan Void, bukan sebagai nota lunas di Daftar Order.
            .where((order) => order.status != OrderStatus.void_)
            .where(
              (o) =>
                  o.orderNumber == 'OFFLINE' ||
                  o.isActive ||
                  isToday(o.createdAt),
            )
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    _sortedCache = list;
    _lastActive = s.activeOrders;
    _lastCompleted = s.completedOrders;
    _lastOfflineLen = offlineLen;
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.menu, size: 22),
          onPressed: KasirShell.openMenu,
        ),
        title: Text(
          'Daftar Order',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: AppColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
        actions: [
          BlocBuilder<OrdersBloc, OrdersState>(
            builder: (context, state) => IconButton(
              tooltip: 'Muat ulang',
              icon: state.loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 22),
              onPressed: () =>
                  context.read<OrdersBloc>().add(OrdersRefreshRequested()),
            ),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: const Divider(height: 1, color: AppColors.border),
        ),
      ),
      body: BlocBuilder<OrdersBloc, OrdersState>(
        builder: (context, state) {
          if (state.loading && state.activeOrders.isEmpty) {
            return const ListSkeleton();
          }
          if (state.error != null &&
              state.activeOrders.isEmpty &&
              state.completedOrders.isEmpty &&
              _offlineOrders(state.outletId).isEmpty) {
            return AppErrorView(
              message: state.error!,
              onRetry: () =>
                  context.read<OrdersBloc>().add(OrdersRefreshRequested()),
            );
          }

          final all = _allSorted(state);
          final q = _query.trim().toLowerCase();
          var rows = all.where(_tab.match);
          if (q.isNotEmpty) {
            rows = rows.where(
              (o) =>
                  (o.customerName ?? '').toLowerCase().contains(q) ||
                  o.orderNumber.toLowerCase().contains(q),
            );
          }
          final list = rows.toList();

          return Column(
            children: [
              // ── Header padat: KPI strip + toolbar (chips + search) ──
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  children: [
                    LayoutBuilder(
                      builder: (context, c) {
                        final chips = SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final t in _OrderTab.values) ...[
                                _TabChip(
                                  label: t.label,
                                  count: all.where(t.match).length,
                                  selected: t == _tab,
                                  onTap: () => setState(() => _tab = t),
                                ),
                                if (t != _OrderTab.values.last)
                                  const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        );
                        final search = AppSearchField(
                          height: 38,
                          hint: 'Cari nama / no order…',
                          onChanged: (v) => setState(() => _query = v),
                        );
                        if (c.maxWidth >= 640) {
                          return Row(
                            children: [
                              Expanded(child: chips),
                              const SizedBox(width: 12),
                              SizedBox(width: 280, child: search),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: chips,
                            ),
                            const SizedBox(height: 8),
                            search,
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),

              // Transaksi yang masih aman di perangkat dan menunggu server.
              _PendingSyncBanner(),

              // ── Banner dead-letter: transaksi offline yang ditolak server ──
              _DeadLetterBanner(),

              // ── Order grid (padat, banyak kolom) ────────────────
              Expanded(
                child: list.isEmpty
                    ? const _EmptyOrders()
                    : RefreshIndicator(
                        onRefresh: () async => context.read<OrdersBloc>().add(
                          OrdersRefreshRequested(),
                        ),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final cols = c.maxWidth >= 760
                                ? 3
                                : c.maxWidth >= 520
                                ? 2
                                : 1;
                            return GridView.builder(
                              padding: const EdgeInsets.all(16),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: cols,
                                    // Beri ruang aman untuk metrik font Android
                                    // pada layar ber-DPR tinggi. Tinggi 264 dapat
                                    // overflow 2 px pada perangkat 360×800.
                                    mainAxisExtent: 270,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              itemCount: list.length,
                              itemBuilder: (_, i) => _OrderCard(order: list[i]),
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PendingSyncBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final q = OfflineQueueService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: q.pendingCount,
      builder: (context, count, _) {
        if (count <= 0) return const SizedBox.shrink();
        String? currentUserId;
        try {
          currentUserId = Supabase.instance.client.auth.currentUser?.id;
        } catch (_) {
          // Widget test / startup sangat awal: tetap tampilkan jumlah antrean.
        }
        final waitingForOtherCashier = currentUserId == null
            ? 0
            : q
                  .all()
                  .where(
                    (entry) =>
                        entry.value['createdBy'] != null &&
                        entry.value['createdBy'] != currentUserId,
                  )
                  .length;
        final message = waitingForOtherCashier > 0
            ? '$count transaksi tersimpan aman. '
                  '$waitingForOtherCashier menunggu akun kasir pembuat login kembali.'
            : '$count transaksi tersimpan aman dan menunggu sinkronisasi.';
        return Container(
          width: double.infinity,
          color: const Color(0xFFFFF8E1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                size: 18,
                color: Color(0xFF8D6E00),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF6D5200),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  SyncService.instance.sync();
                  AppToast.info(context, 'Antrean sinkronisasi diperiksa…');
                },
                child: const Text('Sinkronkan'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Banner peringatan bila ada transaksi offline yang DITOLAK server saat sinkron
/// (dead-letter). Kasir bisa "Coba Lagi" atau membuang. Sembunyi bila kosong.
class _DeadLetterBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final q = OfflineQueueService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: q.deadCount,
      builder: (context, count, _) {
        if (count <= 0) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: const Color(0xFFFCECEC),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              const Icon(
                Icons.sync_problem,
                size: 18,
                color: Color(0xFFC62828),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$count transaksi gagal tersinkron (ditolak server).',
                  style: const TextStyle(
                    color: Color(0xFF8A1F1F),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  await q.retryAllDeadLetters();
                  SyncService.instance.sync();
                  if (context.mounted) {
                    AppToast.info(context, 'Mencoba sinkron ulang…');
                  }
                },
                child: const Text('Coba Lagi'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: selected ? kBrandRed : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: selected ? null : Border.all(color: kTabBorder, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : kTextSecondary,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.22)
                      : Colors.black.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : kTextSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Order order;
  const _OrderCard({required this.order});

  bool get _isOffline => order.orderNumber == 'OFFLINE';

  @override
  Widget build(BuildContext context) {
    final items = order.items ?? const <OrderItem>[];
    const maxRows = 4;
    final shown = items.take(maxRows).toList();
    final moreCount = items.length - shown.length;
    final type = _typeBadgeMeta(order);
    final st = _statusBadgeMeta(_displayOrderStatus(order));

    return GestureDetector(
      onTap: () => _openOrderDetail(context, order),
      child: Container(
        decoration: BoxDecoration(
          color: kCardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kCardBorder, width: 0.5),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header: avatar + nama/order + badges ──────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kAvatarBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _avatarText(order),
                    style: const TextStyle(
                      color: kAvatarText,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.customerName ?? 'Tanpa Pelanggan',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: kTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        order.tableNumber != null
                            ? '#${order.orderNumber} · Meja ${order.tableNumber}'
                            : '#${order.orderNumber}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: kTextMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _isOffline
                        ? const BadgeLabel(
                            text: 'Offline',
                            backgroundColor: kStatusProcessBg,
                            textColor: kStatusProcessText,
                          )
                        : BadgeLabel(
                            text: st.label,
                            backgroundColor: st.bg,
                            textColor: st.text,
                          ),
                    const SizedBox(height: 4),
                    BadgeLabel(
                      text: type.label,
                      backgroundColor: type.bg,
                      textColor: type.text,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Header kolom item ──────────────────────────────────
            Row(
              children: [
                Expanded(flex: 5, child: Text('ITEM', style: _kColHead)),
                Expanded(
                  flex: 2,
                  child: Text(
                    'QTY',
                    textAlign: TextAlign.center,
                    style: _kColHead,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'HARGA',
                    textAlign: TextAlign.right,
                    style: _kColHead,
                  ),
                ),
              ],
            ),
            const Divider(height: 1, thickness: 0.5, color: kDividerHeader),

            // ── Baris item ─────────────────────────────────────────
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Tidak ada item',
                  style: TextStyle(
                    fontSize: 11,
                    color: kTextMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              )
            else
              for (final it in shown)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Text(
                          it.menuItem?.name ?? 'Item',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${it.quantity}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          CurrencyFormatter.format(it.subtotal),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            if (moreCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '+$moreCount item lainnya',
                  style: const TextStyle(fontSize: 10, color: kTextMuted),
                ),
              ),

            const Spacer(),

            // ── Total ──────────────────────────────────────────────
            const Divider(height: 1, thickness: 0.5, color: kDividerTotal),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text(
                  'Total',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: kTextPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  CurrencyFormatter.format(order.totalAmount),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: kTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Tombol aksi per status ─────────────────────────────
            _buildActionButtons(context),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final bloc = context.read<OrdersBloc>();
    final detail = OrderButton(
      label: 'Detail',
      backgroundColor: Colors.white,
      textColor: kDetailText,
      borderColor: kDetailBorder,
      onPressed: () => _openOrderDetail(context, order),
    );
    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 8),
        Expanded(child: b),
      ],
    );

    if (_isOffline) {
      return Row(children: [Expanded(child: detail)]);
    }
    // Lunas PENUH (status paid atau pembayaran ≥ total) → tampil status.
    // Bukan sekadar hasPayment, agar split bill yang baru bayar sebagian tidak
    // salah tampil "Lunas". Tap "Lunas" → buka detail (bisa refund di sana).
    if (order.isFullyPaid) {
      return pair(
        detail,
        OrderButton(
          label: 'Lunas',
          backgroundColor: kBtnLunas,
          textColor: Colors.white,
          onPressed: () => _openOrderDetail(context, order),
        ),
      );
    }
    // Batal / void → hanya detail.
    if (order.status == OrderStatus.cancelled ||
        order.status == OrderStatus.void_) {
      return Row(children: [Expanded(child: detail)]);
    }
    // Order baru / web (draft) → kasir pilih: kirim ke dapur ATAU bayar dulu.
    if (order.status == OrderStatus.draft) {
      return pair(
        OrderButton(
          label: 'Ke Dapur',
          backgroundColor: kBtnProses,
          textColor: Colors.white,
          onPressed: () => bloc.add(
            OrderSendToKitchenRequested(
              order.id,
              order.outletId,
              printedBy: _currentStaffName(context),
            ),
          ),
        ),
        OrderButton(
          label: 'Bayar',
          backgroundColor: kBtnBayar,
          textColor: Colors.white,
          onPressed: () => _openPaymentSheet(context, order),
        ),
      );
    }
    // Sudah di dapur (confirmed/preparing/ready/served), belum bayar → kasir Bayar.
    // Masak & sajikan = urusan dapur (Antrean Dapur), bukan kasir.
    return pair(
      detail,
      OrderButton(
        label: 'Bayar',
        backgroundColor: kBtnBayar,
        textColor: Colors.white,
        onPressed: () => _openPaymentSheet(context, order),
      ),
    );
  }
}

const _kColHead = TextStyle(
  fontSize: 10,
  color: kColHead,
  letterSpacing: 0.5,
  fontWeight: FontWeight.w600,
);

({Color bg, Color text, String label}) _typeBadgeMeta(Order order) =>
    switch (order.orderType) {
      OrderType.dineIn => (bg: kDineInBg, text: kDineInText, label: 'Dine In'),
      OrderType.takeaway => (
        bg: kTakeawayBg,
        text: kTakeawayText,
        label: 'Takeaway',
      ),
      OrderType.selfOrder => (
        bg: kOnlineBg,
        text: kOnlineText,
        label: switch (order.customerServiceMode) {
          'pickup' => 'QR · Bawa Pulang',
          'dine_in' => 'QR · Makan di Tempat',
          _ => 'Order QR',
        },
      ),
    };

/// Pembayaran dan status order tersimpan terpisah. Daftar order harus langsung
/// menampilkan "Lunas" ketika jumlah pembayaran sudah menutup tagihan, termasuk
/// ketika objek realtime masih membawa status `confirmed`.
OrderStatus _displayOrderStatus(Order order) =>
    order.isFullyPaid ? OrderStatus.paid : order.status;

({Color bg, Color text, String label}) _statusBadgeMeta(OrderStatus s) =>
    switch (s) {
      OrderStatus.draft => (
        bg: kStatusDraftBg,
        text: kStatusDraftText,
        label: 'Draft',
      ),
      OrderStatus.confirmed => (
        bg: kStatusConfirmBg,
        text: kStatusConfirmText,
        label: 'Dikonfirmasi',
      ),
      OrderStatus.preparing => (
        bg: kStatusProcessBg,
        text: kStatusProcessText,
        label: 'Diproses',
      ),
      OrderStatus.ready => (
        bg: kStatusDoneBg,
        text: kStatusDoneText,
        label: 'Siap',
      ),
      OrderStatus.served => (
        bg: kStatusServeBg,
        text: kStatusServeText,
        label: 'Disajikan',
      ),
      OrderStatus.paid => (
        bg: kStatusDoneBg,
        text: kStatusDoneText,
        label: 'Lunas',
      ),
      OrderStatus.cancelled => (
        bg: kStatusCancelBg,
        text: kStatusCancelText,
        label: 'Batal',
      ),
      OrderStatus.void_ => (
        bg: kStatusDraftBg,
        text: kStatusDraftText,
        label: 'Void',
      ),
    };

class _OfflineChip extends StatelessWidget {
  const _OfflineChip();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off, size: 12, color: AppColors.warning),
        SizedBox(width: 4),
        Text(
          'OFFLINE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppColors.warning,
          ),
        ),
      ],
    ),
  );
}

String _avatarText(Order o) {
  if (o.orderType == OrderType.takeaway) return 'TA';
  if (o.orderType == OrderType.selfOrder) return 'QR';
  final t = o.tableNumber;
  if (t != null && t.isNotEmpty) return 'M$t';
  final n = (o.customerName ?? '').trim();
  if (n.isEmpty) return '–';
  final parts = n.split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
  return n.substring(0, n.length >= 2 ? 2 : 1).toUpperCase();
}

void _openPaymentSheet(BuildContext context, Order order) {
  final bloc = context.read<OrdersBloc>();
  final shiftBloc = context.read<ShiftBloc>();
  showDialog(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 680),
        child: _PaymentSheet(
          order: order,
          bloc: bloc,
          shiftBloc: shiftBloc,
          popUnderlying: false,
        ),
      ),
    ),
  );
}

enum _OrderCat { semua, kasir, online }

extension _OrderCatX on _OrderCat {
  String get label => switch (this) {
    _OrderCat.semua => 'Semua',
    _OrderCat.kasir => 'Kasir',
    _OrderCat.online => 'Order Online',
  };

  bool match(Order o) => switch (this) {
    _OrderCat.semua => true,
    _OrderCat.kasir =>
      o.orderType == OrderType.dineIn || o.orderType == OrderType.takeaway,
    _OrderCat.online => o.orderType == OrderType.selfOrder,
  };
}

// Lebar relatif kolom tabel (header & baris pakai nilai sama)
const _colFlex = <int>[
  3,
  3,
  3,
  3,
  3,
  2,
]; // Jenis, Nama, No, Tanggal, Status, Tagihan

class _OrderListView extends StatefulWidget {
  final bool embedded; // true = ditanam di Laporan (tanpa AppBar/drawer)
  const _OrderListView({this.embedded = false});

  @override
  State<_OrderListView> createState() => _OrderListViewState();
}

class _OrderListViewState extends State<_OrderListView> {
  _OrderCat _cat = _OrderCat.semua;
  String _query = '';

  // Tampilkan: semua transaksi HARI INI (semua status) + SEMUA order yang masih
  // aktif (belum lunas/batal/void) walau dibuat kemarin + draf offline. Sama
  // dengan tampilan kartu agar konsisten.
  List<Order> _allSorted(OrdersState s) {
    final now = DateTime.now();
    bool isToday(DateTime d) {
      final l = d.toLocal();
      return l.year == now.year && l.month == now.month && l.day == now.day;
    }

    final queued = _offlineOrders(s.outletId);
    final queuedIds = queued.map((order) => order.id).toSet();
    final list =
        [
              ...queued,
              ...s.activeOrders.where((order) => !queuedIds.contains(order.id)),
              ...s.completedOrders.where(
                (order) => !queuedIds.contains(order.id),
              ),
            ]
            .where(
              (o) =>
                  o.orderNumber == 'OFFLINE' ||
                  o.isActive ||
                  isToday(o.createdAt),
            )
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _body(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: KasirShell.openMenu,
        ),
        title: const Text('Daftar Order'),
        actions: [
          BlocBuilder<OrdersBloc, OrdersState>(
            builder: (context, state) => IconButton(
              tooltip: 'Muat ulang',
              icon: state.loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: () =>
                  context.read<OrdersBloc>().add(OrdersRefreshRequested()),
            ),
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return BlocBuilder<OrdersBloc, OrdersState>(
      builder: (context, state) {
        if (state.loading && state.activeOrders.isEmpty) {
          return const ListSkeleton();
        }
        if (state.error != null &&
            state.activeOrders.isEmpty &&
            state.completedOrders.isEmpty &&
            _offlineOrders(state.outletId).isEmpty) {
          return AppErrorView(
            message: state.error!,
            onRetry: () =>
                context.read<OrdersBloc>().add(OrdersRefreshRequested()),
          );
        }

        final all = _allSorted(state);
        final q = _query.trim().toLowerCase();
        var rows = all.where(_cat.match);
        if (q.isNotEmpty) {
          rows = rows.where(
            (o) =>
                (o.customerName ?? '').toLowerCase().contains(q) ||
                o.orderNumber.toLowerCase().contains(q),
          );
        }
        final rowList = rows.toList();

        final sidebar = _CategorySidebar(
          selected: _cat,
          countOf: (c) => all.where(c.match).length,
          onSelect: (c) => setState(() => _cat = c),
        );
        final table = Column(
          children: [
            _SearchField(onChanged: (v) => setState(() => _query = v)),
            const _TableHeader(),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: rowList.isEmpty
                  ? const _EmptyOrders()
                  : RefreshIndicator(
                      onRefresh: () async => context.read<OrdersBloc>().add(
                        OrdersRefreshRequested(),
                      ),
                      child: ListView.separated(
                        itemCount: rowList.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: AppColors.border),
                        itemBuilder: (_, i) => _OrderRow(order: rowList[i]),
                      ),
                    ),
            ),
          ],
        );
        return LayoutBuilder(
          builder: (context, c) {
            // Lebar (tablet): sidebar kategori di samping.
            if (c.maxWidth >= 700) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 220, child: sidebar),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(child: table),
                ],
              );
            }
            // Sempit (HP): kategori di atas (scroll internal), tabel di bawah.
            return Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 132),
                  child: sidebar,
                ),
                const Divider(height: 1, color: AppColors.border),
                Expanded(child: table),
              ],
            );
          },
        );
      },
    );
  }
}

/// Semua order lokal yang belum tersinkron. Transaksi yang sudah dibayar tetap
/// tampil sebagai `paid`, tetapi nomor `OFFLINE` membatasi aksi server sampai
/// antreannya benar-benar diterima backend.
List<Order> _offlineOrders(String outletId) =>
    OrdersDatasource().queuedOrders(outletId);

class _CategorySidebar extends StatelessWidget {
  final _OrderCat selected;
  final int Function(_OrderCat) countOf;
  final ValueChanged<_OrderCat> onSelect;
  const _CategorySidebar({
    required this.selected,
    required this.countOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Kategori Order',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          for (final c in _OrderCat.values)
            _CategoryTile(
              label: '${c.label} (${countOf(c)})',
              selected: c == selected,
              onTap: () => onSelect(c),
            ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.primary : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchField({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: AppSearchField(
        hint: 'Cari nama / no transaksi...',
        onChanged: onChanged,
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    const titles = [
      'Jenis',
      'Nama',
      'No Transaksi',
      'Tanggal',
      'Status',
      'Tagihan',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          for (int i = 0; i < titles.length; i++)
            Expanded(
              flex: _colFlex[i],
              child: Text(
                titles[i],
                textAlign: i == titles.length - 1
                    ? TextAlign.right
                    : TextAlign.left,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  final Order order;
  const _OrderRow({required this.order});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openOrderDetail(context, order),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Jenis
            Expanded(
              flex: _colFlex[0],
              child: Row(
                children: [
                  Icon(
                    _orderTypeIcon(order.orderType),
                    size: 18,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _orderTypeLabel(order),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            // Nama
            Expanded(
              flex: _colFlex[1],
              child: Text(
                order.customerName ?? 'Tanpa Pelanggan',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            // No Transaksi
            Expanded(
              flex: _colFlex[2],
              child: Text(
                '#${order.orderNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            // Tanggal
            Expanded(
              flex: _colFlex[3],
              child: Text(
                _fmtDate(order.createdAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            // Status
            Expanded(
              flex: _colFlex[4],
              child: Align(
                alignment: Alignment.centerLeft,
                child: order.orderNumber == 'OFFLINE'
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_off,
                              size: 12,
                              color: AppColors.warning,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'OFFLINE',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.warning,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _StatusBadge(status: _displayOrderStatus(order)),
              ),
            ),
            // Tagihan
            Expanded(
              flex: _colFlex[5],
              child: Text(
                CurrencyFormatter.format(order.totalAmount),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _orderTypeIcon(OrderType type) => switch (type) {
  OrderType.dineIn => Icons.table_restaurant,
  OrderType.takeaway => Icons.shopping_bag_outlined,
  OrderType.selfOrder => Icons.qr_code,
};

String _orderTypeLabel(Order o) => switch (o.orderType) {
  OrderType.dineIn =>
    o.tableNumber != null ? 'Dine In · Meja ${o.tableNumber}' : 'Dine In',
  OrderType.takeaway => 'Takeaway',
  OrderType.selfOrder =>
    o.customerServiceLabel == null
        ? 'Order QR'
        : 'QR · ${o.customerServiceLabel}',
};

const _idMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'Mei',
  'Jun',
  'Jul',
  'Agu',
  'Sep',
  'Okt',
  'Nov',
  'Des',
];
String _fmtDate(DateTime dt) {
  final l = dt.toLocal();
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${_idMonths[l.month - 1]} ${l.year}, $h:$m';
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.inbox_outlined,
      title: 'Belum ada order masuk',
      subtitle: 'Order baru dari pelanggan akan muncul di sini',
    );
  }
}

void _openOrderDetail(BuildContext context, Order order) {
  final bloc = context.read<OrdersBloc>();
  final shiftBloc = context.read<ShiftBloc>();
  // Modal tengah (tap luar tutup). _OrderDetailSheet mengatur ukuran & animasi.
  showDialog(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: _OrderDetailSheet(order: order, shiftBloc: shiftBloc),
    ),
  );
}

/// Pesanan online hanya boleh diedit penuh sebelum masuk proses dapur dan
/// sebelum pembayaran pertama tercatat.
bool canEditOnlineOrder(Order order) =>
    order.orderType == OrderType.selfOrder &&
    (order.status == OrderStatus.draft ||
        order.status == OrderStatus.confirmed) &&
    !order.hasPayment;

/// Lanjutkan sebuah order draft atau pesanan online yang masih menunggu ke
/// keranjang POS.
///
/// Order yang sudah dicetak/dikirim ke dapur tidak boleh diedit sebagai draft:
/// transaksi tersebut sudah menjadi jejak penjualan dan perubahan item harus
/// dilakukan lewat "Tambah Pesanan", Void, atau Refund sesuai statusnya.
Future<void> _recallOrder(
  BuildContext context,
  OrdersBloc ordersBloc,
  Order order,
) async {
  final editingOnline = canEditOnlineOrder(order);
  if (order.status != OrderStatus.draft && !editingOnline) {
    AppToast.info(
      context,
      order.orderType == OrderType.selfOrder
          ? 'Pesanan online hanya dapat diedit sebelum masuk proses dapur dan sebelum dibayar.'
          : 'Order yang sudah dicetak tidak dapat diedit. Gunakan Tambah Pesanan atau Void.',
    );
    return;
  }

  final items = order.items;
  if (items == null || items.isEmpty) {
    AppToast.error(context, 'Order tidak punya item untuk diedit.');
    return;
  }
  final posBloc = context.read<PosBloc>();
  final router = GoRouter.of(context);
  try {
    final optionsByItem = await OrdersDatasource().fetchOrderItemOptions(
      items.map((i) => i.id).toList(),
    );
    const uuid = Uuid();
    final cartItems = <CartItem>[];
    for (final it in items) {
      if (it.menuItem == null) continue;
      final extras = (optionsByItem[it.id] ?? const [])
          .map(
            (o) => SelectedExtra(
              menuExtraId: o['menu_extra_id'] as String,
              menuExtraOptionId: o['menu_extra_option_id'] as String,
              extraName: (o['extra_name'] as String?) ?? '',
              optionName: (o['option_name'] as String?) ?? '',
              price: (o['price'] as num?)?.toDouble() ?? 0,
            ),
          )
          .toList();
      cartItems.add(
        CartItem(
          id: uuid.v4(),
          persistedOrderItemId: it.id,
          menuItem: it.menuItem!,
          quantity: it.quantity,
          notes: it.notes,
          selectedExtras: extras,
          overriddenPrice: it.menuItem!.allowPriceOverride
              ? it.unitPrice -
                    extras.fold<double>(0, (sum, extra) => sum + extra.price)
              : null,
        ),
      );
    }
    if (cartItems.isEmpty) {
      if (!context.mounted) return;
      AppToast.error(context, 'Item menu tidak tersedia untuk diedit.');
      return;
    }

    // Jangan hapus order di sini. Kasir masih bisa membatalkan atau
    // mengosongkan keranjang. Order draft lama baru dibersihkan setelah order
    // pengganti berhasil dibuat.
    posBloc.add(
      PosCartLoaded(
        cartItems,
        orderType: order.orderType,
        tableId: order.tableId,
        tableNumber: order.tableNumber,
        customerName: order.customerName,
        editingOrderId: editingOnline ? null : order.id,
        editingOrderNumber: editingOnline ? null : order.orderNumber,
        replaceOrderId: editingOnline ? order.id : null,
        replaceOrderNumber: editingOnline ? order.orderNumber : null,
      ),
    );
    ordersBloc.add(OrdersRefreshRequested());

    if (!context.mounted) return;
    AppToast.info(
      context,
      editingOnline
          ? 'Pesanan online #${order.orderNumber} siap diedit.'
          : 'Order #${order.orderNumber} dimuat ke keranjang untuk diedit.',
    );
    Navigator.pop(context); // tutup detail sheet
    router.go('/kasir');
  } catch (e) {
    if (!context.mounted) return;
    AppToast.error(
      context,
      humanizeError(e, fallback: 'Gagal memuat order untuk diedit.'),
    );
  }
}

/// Baris opsi/extra topping untuk order_item_options. Harga ditampilkan bila
/// kolomnya ada & > 0 (nama kolom bisa price / price_adjustment / extra_price).
String _optionLine(Map<String, dynamic> o) {
  final name = (o['option_name'] as String?) ?? '-';
  final price =
      (o['price'] as num?)?.toDouble() ??
      (o['price_adjustment'] as num?)?.toDouble() ??
      (o['extra_price'] as num?)?.toDouble() ??
      0;
  return price > 0 ? '+ $name (${CurrencyFormatter.format(price)})' : '+ $name';
}

class _OrderDetailSheet extends StatelessWidget {
  final Order order;
  final ShiftBloc shiftBloc;
  const _OrderDetailSheet({required this.order, required this.shiftBloc});

  @override
  Widget build(BuildContext context) {
    final items = order.items ?? [];
    final itemCount = items.fold<int>(0, (s, i) => s + i.quantity);
    final subtotal = items.fold<double>(0, (s, i) => s + i.subtotal);
    final tax = order.taxAmount;
    final service = order.serviceCharge;
    final taxPct = subtotal > 0 ? (tax / subtotal * 100).round() : 0;
    final svcPct = subtotal > 0 ? (service / subtotal * 100).round() : 0;
    final fmt = DateFormat('HH:mm · dd MMM yyyy');
    final st = _statusBadgeMeta(_displayOrderStatus(order));
    final isOffline = order.orderNumber == 'OFFLINE';

    final size = MediaQuery.of(context).size;
    final width = (size.width * 0.92).clamp(320.0, 980.0).toDouble();
    final height = (size.height * 0.92).clamp(420.0, 760.0).toDouble();

    final modal = Center(
      child: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: SizedBox(
          width: width,
          height: height,
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                // ── HEADER ──────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _orderTypeIcon(order.orderType),
                          size: 16,
                          color: const Color(0xFF666666),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '#${order.orderNumber} · ${_orderTypeLabel(order)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF111111),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              fmt.format(order.createdAt.toLocal()),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF999999),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      isOffline
                          ? const _OfflineChip()
                          : BadgeLabel(
                              text: st.label,
                              backgroundColor: st.bg,
                              textColor: st.text,
                              borderRadius: 6,
                              fontSize: 11,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                            ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 14,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── BODY: dua kolom di tablet, bertumpuk di layar sempit ──
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 600;
                      return Flex(
                        direction: compact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Kiri 45% — pelanggan + total + breakdown
                          Expanded(
                            flex: 45,
                            child: Container(
                              color: const Color(0xFFF8F8F8),
                              padding: const EdgeInsets.all(14),
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const _DetailSectionLabel('PELANGGAN'),
                                    const SizedBox(height: 4),
                                    Text(
                                      order.customerName ?? 'Tanpa Pelanggan',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF111111),
                                      ),
                                    ),
                                    if (order.customerOrderNote != null) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFF4D6),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFF0D58A),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'CATATAN PESANAN',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF8A6414),
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              order.customerOrderNote!,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                height: 1.35,
                                                color: Color(0xFF4A3A16),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 14),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF111111),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        children: [
                                          const Text(
                                            'Total Bayar',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Color(0x80FFFFFF),
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            CurrencyFormatter.format(
                                              order.totalAmount,
                                            ),
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$itemCount item',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0x66FFFFFF),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    _kv(
                                      'Subtotal',
                                      CurrencyFormatter.format(subtotal),
                                    ),
                                    if (tax > 0) ...[
                                      const SizedBox(height: 3),
                                      _kv(
                                        'Pajak ($taxPct%)',
                                        CurrencyFormatter.format(tax),
                                      ),
                                    ],
                                    if (service > 0) ...[
                                      const SizedBox(height: 3),
                                      _kv(
                                        'Biaya Layanan ($svcPct%)',
                                        CurrencyFormatter.format(service),
                                      ),
                                    ],
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      child: Divider(
                                        height: 0.5,
                                        thickness: 0.5,
                                        color: Color(0xFFE0E0E0),
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text(
                                          'Total',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF111111),
                                          ),
                                        ),
                                        Text(
                                          CurrencyFormatter.format(
                                            order.totalAmount,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF111111),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // Kanan 55% — daftar item (scrollable)
                          Expanded(
                            flex: 55,
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(14),
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const _DetailSectionLabel('PESANAN'),
                                    const SizedBox(height: 8),
                                    FutureBuilder<
                                      Map<String, List<Map<String, dynamic>>>
                                    >(
                                      future: OrdersDatasource()
                                          .fetchOrderItemOptions(
                                            items
                                                .map((e) => e.id)
                                                .where((id) => id.isNotEmpty)
                                                .toList(),
                                          ),
                                      builder: (context, snap) {
                                        final opts = snap.data ?? const {};
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            for (final item in items)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 6,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 6,
                                                                vertical: 2,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color: const Color(
                                                              0xFFFFECEC,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  4,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            '${item.quantity}×',
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 10,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: Color(
                                                                    0xFFB03030,
                                                                  ),
                                                                ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            item
                                                                    .menuItem
                                                                    ?.name ??
                                                                '-',
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 12,
                                                                  color: Color(
                                                                    0xFF333333,
                                                                  ),
                                                                ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        Text(
                                                          CurrencyFormatter.format(
                                                            item.subtotal,
                                                          ),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                                color: Color(
                                                                  0xFF555555,
                                                                ),
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                    // Extra topping / opsi
                                                    for (final o
                                                        in (opts[item.id] ??
                                                            const <
                                                              Map<
                                                                String,
                                                                dynamic
                                                              >
                                                            >[]))
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              left: 32,
                                                              top: 2,
                                                            ),
                                                        child: Text(
                                                          _optionLine(o),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 11,
                                                                color: Color(
                                                                  0xFF999999,
                                                                ),
                                                              ),
                                                        ),
                                                      ),
                                                    // Catatan item
                                                    if (item.notes != null &&
                                                        item.notes!.isNotEmpty)
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              left: 32,
                                                              top: 2,
                                                            ),
                                                        child: Text(
                                                          'Catatan: ${item.notes}',
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 11,
                                                                fontStyle:
                                                                    FontStyle
                                                                        .italic,
                                                                color: Color(
                                                                  0xFFAAAAAA,
                                                                ),
                                                              ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // ── FOOTER ──────────────────────────────────────────────
                // Refund untuk order selesai. Order AKTIF tetap punya aksi
                // transaksi (Bayar/Edit/Bagi/Void) agar fitur tak hilang.
                if (isOffline && order.status == OrderStatus.paid)
                  _scrollableFooter(
                    Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _reprintPaid(context),
                            icon: const Icon(Icons.print_outlined, size: 16),
                            label: const Text('Cetak Ulang Struk'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _offlineNotice(
                          'Pembayaran tersimpan aman dan menunggu sinkronisasi.',
                        ),
                      ],
                    ),
                  )
                else if (isOffline && order.isActive)
                  _scrollableFooter(
                    Column(
                      children: [
                        _ActionButtons(
                          order: order,
                          shiftBloc: shiftBloc,
                          offlineOnly: true,
                        ),
                        const SizedBox(height: 8),
                        _offlineNotice(
                          'Order tersimpan lokal. Bayar, tambah menu, cetak bill, dan cetak dapur tetap tersedia.',
                        ),
                      ],
                    ),
                  )
                else if (order.status == OrderStatus.paid)
                  _scrollableFooter(
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Order sudah lunas — tak ada tombol cetak otomatis lagi,
                        // jadi sediakan reprint manual (struk kasir + tiket dapur).
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _reprintPaid(context),
                            icon: const Icon(Icons.print_outlined, size: 16),
                            label: const Text('Cetak Ulang Struk'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          height: 38,
                          child: OutlinedButton.icon(
                            onPressed: () => _showPartialRefund(context),
                            icon: const Icon(Icons.rule, size: 16),
                            label: const Text(
                              'Refund Sebagian',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _RefundButton(order: order),
                      ],
                    ),
                  )
                else if (order.isActive)
                  _scrollableFooter(
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionButtons(order: order, shiftBloc: shiftBloc),
                        if (order.status == OrderStatus.served) ...[
                          const SizedBox(height: 8),
                          _RefundButton(order: order),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return modal
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(
          begin: const Offset(0.95, 0.95),
          end: const Offset(1, 1),
          duration: 200.ms,
          curve: Curves.easeOut,
        );
  }

  void _reprintPaid(BuildContext context) {
    final auth = context.read<AuthBloc>().state;
    final cashierName = auth is AuthAuthenticated
        ? auth.profile.fullName
        : null;
    showPrintTargetSheet(
      context,
      orderId: order.id,
      outletId: order.outletId,
      cashierName: cashierName,
      orderSnapshot: order,
    );
  }

  Future<void> _showPartialRefund(BuildContext context) async {
    final bloc = context.read<OrdersBloc>();
    final ok = await showPartialRefundDialog(context, order: order);
    if (ok && context.mounted) {
      Navigator.pop(context); // tutup detail sheet
      bloc.add(OrdersRefreshRequested());
    }
  }

  Widget _footerWrap(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFFF0F0F0), width: 0.5)),
    ),
    child: child,
  );

  // Aksi order aktif dapat lebih tinggi daripada dialog (terutama pada layar
  // landscape/bertinggi pendek). Gulirkan footer bila ruang tidak mencukupi.
  Widget _scrollableFooter(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 340),
    child: SingleChildScrollView(child: _footerWrap(child)),
  );

  Widget _kv(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        value,
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
      ),
    ],
  );

  Widget _offlineNotice(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const Icon(Icons.cloud_off, color: AppColors.warning, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Label section detail (PELANGGAN / PESANAN) ───────────────────────────────
class _DetailSectionLabel extends StatelessWidget {
  final String text;
  const _DetailSectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
      color: Color(0xFFBBBBBB),
    ),
  );
}

class _ActionButtons extends StatelessWidget {
  final Order order;
  final ShiftBloc shiftBloc;
  final bool offlineOnly;
  const _ActionButtons({
    required this.order,
    required this.shiftBloc,
    this.offlineOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    // Bayar-di-depan: order sudah lunas tapi masih diproses dapur. Jangan minta
    // bayar lagi (cegah dobel bayar) — tampilkan info status saja.
    // Lunas PENUH (bukan sekadar hasPayment, agar split sebagian tetap bisa
    // dilanjutkan via tombol di bawah). Tampilkan info + opsi refund.
    if (order.isFullyPaid) {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.statusPaid.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  color: AppColors.statusPaid,
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sudah Lunas',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.statusPaid,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Refund order bayar-di-depan (validator izinkan confirmed/preparing/
          // ready → cancelled). 'served' dilewati — otomatis jadi paid saat
          // disajikan, lalu di-refund sebagai order paid.
          if (order.status != OrderStatus.served) ...[
            const SizedBox(height: 10),
            _RefundButton(order: order),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: () => _showPartialRefund(context),
              icon: const Icon(Icons.rule, size: 16),
              label: const Text(
                'Refund Sebagian',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: () => _previewReceipt(context),
              icon: const Icon(Icons.receipt_long_outlined, size: 16),
              label: const Text('Lihat Struk', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: () => _shareReceipt(context),
              icon: const Icon(Icons.share_outlined, size: 16),
              label: const Text(
                'Bagikan Struk',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Pada tablet/browser dengan device-pixel-ratio tinggi, lebar logis
        // dapat berada di bawah 640 walau ruang fisiknya besar. Breakpoint
        // 480 menjaga tombol tetap masuk grid dua kolom pada kondisi tersebut.
        final tablet = constraints.maxWidth >= 480;
        return Column(
          children: [
            // Primary: Bayar tetap paling menonjol.
            SizedBox(
              width: double.infinity,
              height: tablet ? 52 : 48,
              child: FilledButton.icon(
                onPressed: () => _showPaymentSheet(context),
                icon: const Icon(Icons.payment, size: 19),
                label: const Text(
                  'Bayar',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (offlineOnly) ...[
              _actionButton(
                label: 'Tambah Pesanan',
                icon: Icons.add_shopping_cart,
                onPressed: () => _appendToOrder(context),
              ),
              const SizedBox(height: 6),
              _actionButton(
                label: 'Cetak Bill',
                icon: Icons.receipt_long_outlined,
                onPressed: () => _printUnpaidBill(context),
              ),
              const SizedBox(height: 6),
              _actionButton(
                label: 'Cetak Tiket Dapur',
                icon: Icons.soup_kitchen_outlined,
                onPressed: () => _reprintKitchen(context),
              ),
            ] else if (tablet)
              _tabletActionGrid(context)
            else ...[
              if (order.status == OrderStatus.draft ||
                  canEditOnlineOrder(order)) ...[
                _actionButton(
                  label: canEditOnlineOrder(order)
                      ? 'Edit Pesanan'
                      : 'Edit Draft',
                  icon: Icons.edit_outlined,
                  onPressed: () =>
                      _recallOrder(context, context.read<OrdersBloc>(), order),
                ),
                const SizedBox(height: 6),
              ],
              _actionButton(
                label: 'Tambah Pesanan',
                icon: Icons.add_shopping_cart,
                onPressed: () => _appendToOrder(context),
              ),
              const SizedBox(height: 6),
              _actionButton(
                label: 'Cetak Bill',
                icon: Icons.receipt_long_outlined,
                onPressed: () => _printUnpaidBill(context),
              ),
              if (order.orderType == OrderType.dineIn) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        label: 'Pindah Meja',
                        icon: Icons.swap_horiz,
                        onPressed: () => _showTransferTableSheet(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        label: 'Gabung',
                        icon: Icons.merge_type,
                        onPressed: () => _showMergeSheet(context),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              _actionButton(
                label: 'Cetak Tiket Dapur',
                icon: Icons.soup_kitchen_outlined,
                onPressed: () => _reprintKitchen(context),
              ),
              const SizedBox(height: 4),
              _voidButton(context),
            ],
          ],
        );
      },
    );
  }

  Widget _tabletActionGrid(BuildContext context) {
    final actions = <Widget>[];
    if (order.status == OrderStatus.draft || canEditOnlineOrder(order)) {
      actions.add(
        _actionButton(
          label: canEditOnlineOrder(order) ? 'Edit Pesanan' : 'Edit Draft',
          icon: Icons.edit_outlined,
          onPressed: () =>
              _recallOrder(context, context.read<OrdersBloc>(), order),
        ),
      );
    }
    actions.addAll([
      _actionButton(
        label: 'Tambah Pesanan',
        icon: Icons.add_shopping_cart,
        onPressed: () => _appendToOrder(context),
      ),
      _actionButton(
        label: 'Cetak Bill',
        icon: Icons.receipt_long_outlined,
        onPressed: () => _printUnpaidBill(context),
      ),
    ]);
    if (order.orderType == OrderType.dineIn) {
      actions.addAll([
        _actionButton(
          label: 'Pindah Meja',
          icon: Icons.swap_horiz,
          onPressed: () => _showTransferTableSheet(context),
        ),
        _actionButton(
          label: 'Gabung',
          icon: Icons.merge_type,
          onPressed: () => _showMergeSheet(context),
        ),
      ]);
    }
    actions.addAll([
      _actionButton(
        label: 'Cetak Tiket Dapur',
        icon: Icons.soup_kitchen_outlined,
        onPressed: () => _reprintKitchen(context),
      ),
    ]);

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 8) / 2;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in actions)
                  SizedBox(width: itemWidth, child: action),
              ],
            ),
            const SizedBox(height: 8),
            _voidButton(context),
          ],
        );
      },
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) => SizedBox(
    width: double.infinity,
    height: 48,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
  );

  Widget _voidButton(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 48,
    child: OutlinedButton.icon(
      onPressed: () => _showVoidDialog(context),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.error,
        side: BorderSide(color: AppColors.error.withValues(alpha: 0.55)),
      ),
      icon: const Icon(Icons.cancel_outlined, size: 18),
      label: const Text(
        'Void Item',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
  );

  void _reprintKitchen(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showKitchenItemPrintDialog(
      context,
      order: order,
      printedBy: _currentStaffName(context),
    );
    if (result == null) return;
    final message = result.hasPrinted
        ? 'Item terpilih dikirim ke printer dapur'
        : result.hasQueued
        ? 'Printer belum siap. Item terpilih masuk antrean cetak'
        : result.skippedReason ?? 'Tiket dapur belum dapat dicetak';
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Cetak tagihan sebelum pembayaran. Berbeda dari struk pembayaran, bill
  /// adalah aksi manual, boleh dicetak ulang, dan tetap memakai snapshot
  /// outlet/menu lokal ketika internet sedang terputus.
  Future<void> _printUnpaidBill(BuildContext context) async {
    if (!PrinterService.isSupported) {
      AppToast.error(context, 'Cetak bill hanya tersedia di perangkat kasir.');
      return;
    }
    final printer = PrinterService();
    final staffName = _currentStaffName(context);
    try {
      if (await printer.receiptNeedsBluetoothConnect() &&
          !printer.isConnected) {
        final autoOk = await printer.tryAutoReconnect();
        if (!autoOk) {
          if (!context.mounted) return;
          final connected = await showPrinterConnectDialog(context);
          if (!connected) return;
        }
      }

      final pos = PosDatasource();
      Map<String, dynamic>? outletData = pos.cachedOutletReceiptMap(
        order.outletId,
      );
      if (ConnectivityService.instance.online.value) {
        try {
          outletData = await pos.fetchOutletReceiptMap(order.outletId);
        } catch (_) {
          // Snapshot cache tetap cukup untuk operasional saat jaringan putus.
        }
      }
      if (outletData == null) {
        throw StateError('Data outlet belum pernah tersimpan di perangkat');
      }

      final target = await printer.printerForReceipt();
      final builder = ReceiptBuilder(
        outlet: OutletReceiptInfo.fromMap(outletData),
        paperSize: target?.paper == '80' ? PaperSize.mm80 : PaperSize.mm58,
        driver: target?.driver ?? 'generic1',
      );
      final bytes = await builder.build(
        order: order,
        paymentBreakdown: const {},
        cashierName: staffName,
        customerName: order.customerName,
        waiterName: staffName,
        documentTitle: 'BILL - BELUM LUNAS',
      );
      final outcome = await printer.printReceiptBytes(bytes);
      if (!context.mounted) return;
      if (outcome.isPrinted) {
        AppToast.success(context, 'Bill belum lunas berhasil dicetak.');
      } else {
        AppToast.error(
          context,
          outcome.isFailed
              ? 'Bill gagal dicetak. Periksa printer.'
              : 'Belum ada printer dengan peran Struk.',
        );
      }
    } catch (error) {
      if (context.mounted) {
        AppToast.error(
          context,
          humanizeError(error, fallback: 'Bill gagal dicetak.'),
        );
      }
    }
  }

  // Pindah order ke meja lain. Menampilkan daftar meja outlet; trigger DB
  // membebaskan meja lama & menempati meja baru.
  void _showTransferTableSheet(BuildContext context) async {
    final ordersBloc = context.read<OrdersBloc>();
    final ds = OrdersDatasource();
    List<Map<String, dynamic>> tables;
    try {
      tables = await ds.fetchTables(order.outletId);
    } catch (e) {
      if (context.mounted) AppToast.error(context, humanizeError(e));
      return;
    }
    if (!context.mounted) return;
    // Sisakan meja selain meja saat ini.
    final options = tables.where((t) => t['id'] != order.tableId).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Pindah ke Meja',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Tidak ada meja lain tersedia.'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in options)
                      ListTile(
                        leading: const Icon(Icons.table_restaurant_outlined),
                        title: Text('Meja ${t['table_number']}'),
                        subtitle: (t['area'] as String?)?.isNotEmpty ?? false
                            ? Text(t['area'] as String)
                            : null,
                        trailing: t['status'] == 'occupied'
                            ? const Text(
                                'Terisi',
                                style: TextStyle(
                                  color: AppColors.error,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        onTap: () async {
                          Navigator.pop(sheetCtx);
                          try {
                            await ds.transferTable(order.id, t['id'] as String);
                            ordersBloc.add(OrdersRefreshRequested());
                            if (context.mounted) {
                              Navigator.pop(context); // tutup detail
                              AppToast.success(
                                context,
                                'Order dipindah ke Meja ${t['table_number']}.',
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              AppToast.error(context, humanizeError(e));
                            }
                          }
                        },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Gabungkan order ini ke order dine-in aktif lain (bill jadi satu).
  void _showMergeSheet(BuildContext context) {
    final ordersBloc = context.read<OrdersBloc>();
    final ds = OrdersDatasource();
    final targets = ordersBloc.state.activeOrders
        .where(
          (o) =>
              o.id != order.id &&
              o.orderType == OrderType.dineIn &&
              o.orderNumber != 'OFFLINE',
        )
        .toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Gabung #${order.orderNumber} ke…',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (targets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Tidak ada order dine-in aktif lain.'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in targets)
                      ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text('Order #${t.orderNumber}'),
                        subtitle: Text(
                          t.tableNumber != null
                              ? 'Meja ${t.tableNumber} · ${CurrencyFormatter.format(t.totalAmount)}'
                              : CurrencyFormatter.format(t.totalAmount),
                        ),
                        onTap: () async {
                          Navigator.pop(sheetCtx);
                          try {
                            await ds.mergeOrders(order.id, t.id);
                            ordersBloc.add(OrdersRefreshRequested());
                            if (context.mounted) {
                              Navigator.pop(context); // tutup detail
                              AppToast.success(
                                context,
                                'Digabung ke Order #${t.orderNumber}.',
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              AppToast.error(context, humanizeError(e));
                            }
                          }
                        },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Masuk mode "tambah pesanan": buka POS dengan keranjang kosong terikat ke
  // order ini. Item yang ditambahkan akan disisipkan ke order (bukan order baru).
  void _appendToOrder(BuildContext context) {
    final posBloc = context.read<PosBloc>();
    final router = GoRouter.of(context);
    posBloc.add(
      PosCartLoaded(
        const [],
        orderType: order.orderType,
        tableId: order.tableId,
        tableNumber: order.tableNumber,
        appendOrderId: order.id,
        appendOrderNumber: order.orderNumber,
      ),
    );
    Navigator.pop(context); // tutup detail sheet
    router.go('/kasir');
  }

  void _showPaymentSheet(BuildContext context) {
    final bloc = context.read<OrdersBloc>();
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 680),
          child: _PaymentSheet(order: order, bloc: bloc, shiftBloc: shiftBloc),
        ),
      ),
    );
  }

  void _showVoidDialog(BuildContext context) async {
    final bloc = context.read<OrdersBloc>();
    Map<String, dynamic>? voidResult;
    final ok = await showItemVoidDialog(
      context,
      order: order,
      onVoided: (result) => voidResult = result,
    );
    if (ok && context.mounted) {
      final remainingById = <String, int>{};
      final result = voidResult;
      if (result != null) {
        for (final entry in result['items'] as List? ?? const []) {
          if (entry is Map) {
            final itemId = entry['order_item_id'] as String?;
            final remaining = entry['quantity_after'] as num?;
            if (itemId != null && remaining != null) {
              remainingById[itemId] = remaining.toInt();
            }
          }
        }
        context.read<PosBloc>().add(
          PosPersistedItemsVoided(
            order.id,
            remainingById,
            orderVoided: result['order_status'] == 'void',
          ),
        );
      }
      Navigator.pop(context); // tutup detail sheet
      bloc.add(OrdersRefreshRequested());
    }
  }

  void _showPartialRefund(BuildContext context) async {
    final bloc = context.read<OrdersBloc>();
    final ok = await showPartialRefundDialog(context, order: order);
    if (ok && context.mounted) {
      Navigator.pop(context); // tutup detail sheet
      bloc.add(OrdersRefreshRequested());
    }
  }

  // Bagikan struk digital (PDF) via share sheet OS (WhatsApp/email/simpan).
  void _shareReceipt(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final snapshot = await _receiptSnapshot();
      await shareReceiptPdf(
        order: snapshot.$1,
        outlet: OutletReceiptInfo.fromMap(snapshot.$2),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(humanizeError(e, fallback: 'Gagal membuat struk.')),
        ),
      );
    }
  }

  // Pratinjau struk ON-SCREEN (tanpa cetak/share). Struk transaksi nyata.
  void _previewReceipt(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final snapshot = await _receiptSnapshot();
      final full = snapshot.$1;
      if (!context.mounted) return;
      final paymentBreakdown = receiptPaymentBreakdown(
        full.payments ?? const [],
      );
      await showReceiptPreviewSheet(
        context,
        outlet: OutletReceiptInfo.fromMap(snapshot.$2),
        order: full,
        paymentBreakdown: paymentBreakdown,
        customerName: full.customerName,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(humanizeError(e, fallback: 'Gagal memuat struk.')),
        ),
      );
    }
  }

  /// Sumber struk bersifat local-first. Daftar Order sudah membawa snapshot
  /// item/pembayaran lengkap, sehingga preview/share tidak boleh mendadak
  /// hilang hanya karena Wi-Fi putus. Saat online data server tetap dipakai
  /// sebagai penyegaran terbaik; kegagalannya jatuh kembali ke cache.
  Future<(Order, Map<String, dynamic>)> _receiptSnapshot() async {
    var full = order;
    final pos = PosDatasource();

    if (ConnectivityService.instance.online.value &&
        order.orderNumber != 'OFFLINE') {
      try {
        final orderData = await Supabase.instance.client
            .from('orders')
            .select(
              '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price)), payments(method, amount)',
            )
            .eq('id', order.id)
            .single();
        full = Order.fromJson(orderData);
      } catch (_) {
        // Snapshot dari daftar order tetap valid untuk struk lokal.
      }
    }

    Map<String, dynamic>? outletData = pos.cachedOutletReceiptMap(
      order.outletId,
    );
    if (ConnectivityService.instance.online.value) {
      try {
        outletData = await pos.fetchOutletReceiptMap(order.outletId);
      } catch (_) {
        // Pakai snapshot outlet hasil bootstrap terakhir.
      }
    }
    if (outletData == null) {
      throw StateError(
        'Data outlet belum tersimpan. Hubungkan internet sekali untuk mengunduh data cabang.',
      );
    }
    return (full, outletData);
  }
}

// ── Tombol Refund untuk order paid (butuh PIN) ───────────────────────────────
class _RefundButton extends StatelessWidget {
  final Order order;
  const _RefundButton({required this.order});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 38,
      child: OutlinedButton.icon(
        onPressed: () => _showRefundDialog(context),
        icon: const Icon(
          Icons.refresh_rounded,
          size: 16,
          color: Color(0xFFE24B4A),
        ),
        label: const Text(
          'Refund',
          style: TextStyle(
            color: Color(0xFFE24B4A),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFE24B4A), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  void _showRefundDialog(BuildContext context) async {
    final bloc = context.read<OrdersBloc>();
    final ok = await showRefundOrderDialog(context, order: order);
    if (ok && context.mounted) {
      Navigator.pop(context); // tutup detail sheet
      bloc.add(OrdersRefreshRequested());
    }
  }
}

// ── Payment Sheet (untuk self-order confirmed) ────────────────────────────────

// ── Split bill / bagi tagihan ─────────────────────────────────────────────────
class _SplitBillSheet extends StatefulWidget {
  final Order order;
  final String outletId;
  final OrdersBloc bloc;
  const _SplitBillSheet({
    required this.order,
    required this.outletId,
    required this.bloc,
  });

  @override
  State<_SplitBillSheet> createState() => _SplitBillSheetState();
}

class _SplitBillSheetState extends State<_SplitBillSheet> {
  static const _methods = [
    (PaymentMethod.cash, Icons.money, 'Tunai'),
    (PaymentMethod.qris, Icons.qr_code, 'QRIS'),
    (PaymentMethod.debit, Icons.credit_card, 'Debit'),
    (PaymentMethod.credit, Icons.credit_score, 'Kartu Kredit'),
    (PaymentMethod.ewallet, Icons.account_balance_wallet, 'E-Wallet'),
    (PaymentMethod.transfer, Icons.swap_horiz, 'Transfer'),
  ];

  final _ds = OrdersDatasource();
  final _amountCtrl = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  final List<({PaymentMethod method, double amount})> _splits = [];
  double _initialPaid = 0;
  bool _loading = true;
  String? _loadError;
  bool _busy = false;
  String? _paymentShiftId;
  String? _retryOperationId;
  String? _retrySignature;
  String? _retryIdempotencyKey;
  Set<String> _enabledMethods = const {
    'cash',
    'qris',
    'debit',
    'credit',
    'ewallet',
    'transfer',
  };

  double get _total => widget.order.totalAmount;
  double get _paid =>
      _initialPaid + _splits.fold<double>(0, (s, e) => s + e.amount);
  double get _remaining => (_total - _paid).clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final results = await Future.wait([
        ConnectivityService.instance.online.value
            ? _ds.fetchPaidTotal(widget.order.id)
            : Future<double>.value(widget.order.paidTotal),
        _loadEnabledPaymentMethods(widget.outletId),
      ]);
      if (!mounted) return;
      setState(() {
        _initialPaid = results[0] as double;
        _enabledMethods = results[1] as Set<String>;
        _loading = false;
        _loadError = null;
      });
      _amountCtrl.text = _remaining > 0 ? formatThousands(_remaining) : '';
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = humanizeError(
          error,
          fallback: 'Data pembayaran belum dapat dimuat.',
        );
      });
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPayment() async {
    if (_loading || _loadError != null) {
      AppToast.error(
        context,
        'Muat ulang data pembayaran sebelum menambah pembayaran.',
      );
      return;
    }
    final amt = parseThousands(_amountCtrl.text);
    if (amt <= 0) {
      AppToast.error(context, 'Nominal harus lebih dari 0');
      return;
    }
    // Seluruh metode wajib diatribusikan ke shift penerima. Payment menyimpan
    // shift sendiri sehingga split tunai/nontunai tetap masuk laporan yang sama.
    if (_paymentShiftId == null) {
      final auth = context.read<AuthBloc>().state;
      if (auth is AuthAuthenticated) {
        final res = await resolveCashTill(
          context,
          outletId: widget.outletId,
          sellerId: auth.profile.id,
          isCash: _method == PaymentMethod.cash,
          requireOwnShift: auth.profile.role == UserRole.kasir,
        );
        if (!mounted) return;
        if (res.outcome == TillOutcome.cancelled) return; // batal
        if (res.shiftId == null) {
          if (mounted) {
            AppToast.error(
              context,
              'Pembayaran memerlukan shift kasir terbuka',
            );
          }
          return;
        }
        _paymentShiftId = res.shiftId;
      }
    }
    final capped = amt > _remaining
        ? _remaining
        : amt; // cegah overpay di split
    if (capped <= 0) {
      AppToast.error(context, 'Tagihan sudah lunas atau nominal tidak valid.');
      return;
    }
    if (!mounted) return;
    final completesPayment = capped >= _remaining - 0.01;
    final signature =
        '${widget.order.id}|${_method.value}|$capped|$_paymentShiftId';
    final journal = TransactionJournalService.instance;
    final currentAuth = context.read<AuthBloc>().state;
    final expectedUserId = currentAuth is AuthAuthenticated
        ? currentAuth.profile.id
        : null;
    final operationId =
        _retrySignature == signature && _retryOperationId != null
        ? _retryOperationId!
        : 'split-payment-${const Uuid().v4()}';
    final idempotencyKey =
        _retrySignature == signature && _retryIdempotencyKey != null
        ? _retryIdempotencyKey!
        : const Uuid().v4();
    final existingJournal = journal.get(operationId);
    final paidAt =
        (existingJournal?['payload'] as Map?)?['paidAt'] as String? ??
        ConnectivityService.instance.trustedUtcNow().toIso8601String();
    final localOutbox = OfflineQueueService.instance.findByClientOrderId(
      widget.order.id,
    );
    if (localOutbox != null) {
      final payments = (localOutbox['payments'] as List? ?? const [])
          .whereType<Map>()
          .map((payment) => Map<String, dynamic>.from(payment))
          .toList();
      if (!payments.any(
        (payment) => payment['idempotencyKey'] == idempotencyKey,
      )) {
        payments.add({
          'method': _method.value,
          'amount': capped,
          'idempotencyKey': idempotencyKey,
          'paidAt': paidAt,
          'paidAtClockSource':
              ConnectivityService.instance.hasTrustedServerClock
              ? 'server_offset'
              : 'device',
        });
      }
      final updated = await OfflineQueueService.instance.updateByClientOrderId(
        widget.order.id,
        {
          'payments': payments,
          'shiftId': _paymentShiftId!,
          if (completesPayment) ...{
            'kind': 'paid',
            'paidAt': paidAt,
            'paidAtClockSource':
                ConnectivityService.instance.hasTrustedServerClock
                ? 'server_offset'
                : 'device',
          },
        },
      );
      if (updated == null) {
        throw StateError('Order lokal tidak ditemukan di antrean aman');
      }
      await _ds.cacheQueuedOrder(updated);
      setState(() => _busy = true);
      await _acceptOfflineSplit(
        operationId: null,
        paymentId: idempotencyKey,
        paidAt: paidAt,
        amount: capped,
        completesPayment: completesPayment,
      );
      return;
    }
    if (existingJournal == null) {
      await journal.enqueue(
        id: operationId,
        type: 'split_payment',
        payload: {
          'orderId': widget.order.id,
          'outletId': widget.outletId,
          'shiftId': _paymentShiftId!,
          'method': _method.value,
          'amount': capped,
          'finalize': completesPayment,
          'idempotencyKey': idempotencyKey,
          'expectedUserId': expectedUserId,
          'paidAt': paidAt,
          'paidAtClockSource':
              ConnectivityService.instance.hasTrustedServerClock
              ? 'server_offset'
              : 'device',
        },
      );
    }
    setState(() => _busy = true);
    await journal.markSending(operationId);
    if (!ConnectivityService.instance.online.value) {
      await _acceptOfflineSplit(
        operationId: operationId,
        paymentId: idempotencyKey,
        paidAt: paidAt,
        amount: capped,
        completesPayment: completesPayment,
      );
      return;
    }
    try {
      await _ds.addSplitPayment(
        orderId: widget.order.id,
        outletId: widget.outletId,
        shiftId: _paymentShiftId!,
        method: _method,
        amount: capped,
        finalize: completesPayment,
        idempotencyKey: idempotencyKey,
        paidAt: paidAt,
      );
      await journal.remove(operationId);
      _retryOperationId = null;
      _retrySignature = null;
      _retryIdempotencyKey = null;
      if (!mounted) return;
      setState(() {
        _splits.add((method: _method, amount: capped));
        _busy = false;
        _amountCtrl.text = _remaining > 0 ? formatThousands(_remaining) : '';
      });
      if (completesPayment && mounted) {
        await _finalize();
      }
    } catch (e) {
      if (isBackendTransportFailure(e)) {
        await _acceptOfflineSplit(
          operationId: operationId,
          paymentId: idempotencyKey,
          paidAt: paidAt,
          amount: capped,
          completesPayment: completesPayment,
          error: e,
        );
        return;
      } else {
        await journal.markNeedsReview(operationId, e);
      }
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(
        context,
        humanizeError(e, fallback: 'Gagal mencatat pembayaran.'),
      );
    }
  }

  Future<void> _acceptOfflineSplit({
    required String? operationId,
    required String paymentId,
    required String paidAt,
    required double amount,
    required bool completesPayment,
    Object? error,
  }) async {
    if (operationId != null) {
      await TransactionJournalService.instance.markPending(operationId, error);
    }
    await _ds.applyCachedPayment(
      outletId: widget.outletId,
      orderId: widget.order.id,
      paymentId: paymentId,
      method: _method,
      amount: amount,
      paidAt: paidAt,
      finalize: completesPayment,
    );
    _retryOperationId = null;
    _retrySignature = null;
    _retryIdempotencyKey = null;
    if (!mounted) return;
    setState(() {
      _splits.add((method: _method, amount: amount));
      _busy = false;
      _amountCtrl.text = _remaining > 0 ? formatThousands(_remaining) : '';
    });
    unawaited(SyncService.instance.sync());
    if (completesPayment) {
      await _completeOfflineSplit();
    } else if (mounted) {
      AppToast.success(
        context,
        'Pembayaran bagian tersimpan offline dan akan tersinkron.',
      );
    }
  }

  Future<void> _completeOfflineSplit() async {
    final auth = context.read<AuthBloc>().state;
    final cashierName = auth is AuthAuthenticated
        ? auth.profile.fullName
        : null;
    final breakdown = <PaymentMethod, double>{};
    for (final payment in widget.order.payments ?? const <Payment>[]) {
      breakdown[payment.method] =
          (breakdown[payment.method] ?? 0) + payment.amount;
    }
    for (final split in _splits) {
      breakdown[split.method] = (breakdown[split.method] ?? 0) + split.amount;
    }
    try {
      if (!widget.order.kitchenPrinted) {
        await printKitchenTicketsForLocalOrder(
          order: widget.order,
          categoryNames: PosDatasource().cachedCategoryNames(widget.outletId),
          trigger: KitchenTrigger.bayar,
          printedBy: cashierName,
        );
      }
      if (mounted) {
        await _tryPrintReceipt(
          context: context,
          order: widget.order,
          outletId: widget.outletId,
          paymentBreakdown: breakdown,
          cashierName: cashierName,
        );
      }
    } catch (error, stack) {
      unawaited(ErrorLogService.report(error, stack));
    }
    await OrdersDatasource().setCachedTableStatus(
      outletId: widget.outletId,
      tableId: widget.order.tableId,
      status: 'available',
    );
    widget.bloc.add(OrdersRefreshRequested());
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.pop(context);
    AppToast.success(
      context,
      'Pembayaran lunas tersimpan offline dan akan tersinkron.',
    );
  }

  Future<void> _finalize() async {
    if (_loading || _loadError != null) {
      AppToast.error(
        context,
        'Muat ulang data pembayaran sebelum menyelesaikan transaksi.',
      );
      return;
    }
    setState(() => _busy = true);
    final journal = TransactionJournalService.instance;
    const opPrefix = 'split-finalize-';
    final operationId = '$opPrefix${widget.order.id}';
    final auth = context.read<AuthBloc>().state;
    if (journal.get(operationId) == null) {
      await journal.enqueue(
        id: operationId,
        type: 'split_finalize',
        payload: {
          'orderId': widget.order.id,
          'expectedUserId': auth is AuthAuthenticated ? auth.profile.id : null,
        },
      );
    }
    await journal.markSending(operationId);
    try {
      await _ds.finalizeSplitPayment(widget.order.id);
      await journal.remove(operationId);
      if (!mounted) return;
      final cashierName = auth is AuthAuthenticated
          ? auth.profile.fullName
          : null;
      await _tryPrintFinalizedSplitReceipt(
        context: context,
        orderId: widget.order.id,
        outletId: widget.outletId,
        cashierName: cashierName,
      );
      widget.bloc.add(OrdersRefreshRequested());
      if (!mounted) return;
      Navigator.pop(context); // tutup split sheet
      Navigator.pop(context); // tutup detail sheet
      AppToast.success(context, 'Pembayaran lunas — order diselesaikan.');
    } catch (e) {
      if (isBackendTransportFailure(e)) {
        await journal.markPending(operationId, e);
      } else {
        await journal.markNeedsReview(operationId, e);
      }
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(
        context,
        humanizeError(e, fallback: 'Gagal menyelesaikan pembayaran.'),
      );
    }
  }

  String _label(PaymentMethod m) => _methods.firstWhere((e) => e.$1 == m).$3;

  @override
  Widget build(BuildContext context) {
    final done = _remaining <= 0;
    final methods = _methods
        .where((m) => _enabledMethods.contains(m.$1.value))
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textDisabled,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Bagi Tagihan',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const Spacer(),
                  Text(
                    '#${widget.order.orderNumber}',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_loadError != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.25),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.cloud_off_outlined,
                        color: AppColors.error,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.error),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Coba Muat Ulang'),
                      ),
                    ],
                  ),
                )
              else ...[
                // Ringkasan
                _summaryRow('Total Tagihan', _total, bold: true),
                const SizedBox(height: 4),
                _summaryRow('Terbayar', _paid, color: AppColors.secondary),
                const SizedBox(height: 4),
                _summaryRow(
                  'Sisa',
                  _remaining,
                  color: _remaining > 0 ? AppColors.error : AppColors.secondary,
                  big: true,
                ),
                const Divider(height: 24),

                // Daftar pembayaran tercatat
                if (_initialPaid > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Sudah dibayar sebelumnya: ${CurrencyFormatter.format(_initialPaid)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ..._splits.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 16,
                          color: AppColors.secondary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _label(e.value.method),
                          style: const TextStyle(fontSize: 13),
                        ),
                        const Spacer(),
                        Text(
                          CurrencyFormatter.format(e.value.amount),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (!done) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Tambah Pembayaran',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  // Metode
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: methods.map((m) {
                      final sel = _method == m.$1;
                      return GestureDetector(
                        onTap: () => setState(() => _method = m.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: sel ? AppColors.accent : Colors.white,
                            border: Border.all(
                              color: sel ? AppColors.primary : AppColors.border,
                              width: sel ? 1.5 : 1,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                m.$2,
                                size: 16,
                                color: sel
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                m.$3,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: sel
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                  fontWeight: sel
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _amountCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [ThousandsInputFormatter()],
                          decoration: InputDecoration(
                            prefixText: 'Rp ',
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : _addPayment,
                        child: const Text('Tambah'),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: (done && !_busy) ? _finalize : null,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle),
                    label: Text(
                      done
                          ? 'Selesaikan Pembayaran'
                          : 'Sisa ${CurrencyFormatter.format(_remaining)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryRow(
    String label,
    double value, {
    bool bold = false,
    bool big = false,
    Color? color,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: big ? 16 : 14,
            fontWeight: bold || big ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          CurrencyFormatter.format(value),
          style: TextStyle(
            fontSize: big ? 20 : 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  final Order order;
  final OrdersBloc bloc;
  final ShiftBloc shiftBloc;

  /// true bila dibuka dari detail sheet (perlu pop detail juga setelah bayar).
  /// false bila dibuka langsung dari kartu Daftar Order.
  final bool popUnderlying;
  const _PaymentSheet({
    required this.order,
    required this.bloc,
    required this.shiftBloc,
    this.popUnderlying = true,
  });

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  PaymentMethod _method = PaymentMethod.cash;
  String _input = '';
  bool _processing = false;
  String? _paymentJournalId;
  String? _paymentJournalSignature;
  String? _paymentIdempotencyKey;
  Set<String> _enabledMethods = const {
    'cash',
    'qris',
    'debit',
    'credit',
    'ewallet',
    'transfer',
  };

  static const _methods = [
    (PaymentMethod.cash, Icons.money, 'Tunai'),
    (PaymentMethod.qris, Icons.qr_code, 'QRIS'),
    (PaymentMethod.debit, Icons.credit_card, 'Debit'),
    (PaymentMethod.credit, Icons.credit_score, 'Kartu Kredit'),
    (PaymentMethod.ewallet, Icons.account_balance_wallet, 'E-Wallet'),
    (PaymentMethod.transfer, Icons.swap_horiz, 'Transfer'),
  ];

  @override
  void initState() {
    super.initState();
    _loadPaymentMethods();
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) {
      unawaited(PosDatasource().warmPrintCaches(auth.profile.outletId ?? ''));
    }
  }

  Future<void> _loadPaymentMethods() async {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return;
    final methods = await _loadEnabledPaymentMethods(
      auth.profile.outletId ?? '',
    );
    if (!mounted) return;
    setState(() {
      _enabledMethods = methods;
      if (!_enabledMethods.contains(_method.value)) {
        _method = PaymentMethod.cash;
      }
    });
  }

  // Nominal yang harus dibayar SEKARANG = sisa tagihan (mendukung split bill
  // yang sudah bayar sebagian). Order baru → paidTotal 0 → = total penuh.
  double get _total => (widget.order.totalAmount - widget.order.paidTotal)
      .clamp(0, double.infinity);
  double get _received => double.tryParse(_input) ?? 0;
  double get _kembalian => _received - _total;
  bool get _isCash => _method == PaymentMethod.cash;
  bool get _canPay => !_processing && (!_isCash || _received >= _total);

  void _onNumpad(String key) {
    setState(() {
      if (key == '⌫') {
        if (_input.isNotEmpty) _input = _input.substring(0, _input.length - 1);
      } else if (key == '000') {
        if (_input.isNotEmpty) _input += '000';
      } else {
        if (_input.length < 12) _input += key;
      }
    });
  }

  Future<void> _confirmPayment() async {
    setState(() => _processing = true);
    try {
      final authState = context.read<AuthBloc>().state;
      final outletId = authState is AuthAuthenticated
          ? authState.profile.outletId ?? ''
          : '';
      final cashierName = authState is AuthAuthenticated
          ? authState.profile.fullName
          : null;

      final localOutbox = OfflineQueueService.instance.findByClientOrderId(
        widget.order.id,
      );

      // Ambil total DAN pembayaran terbaru dalam satu response. Membaca hanya
      // paid_total tidak cukup: item dapat di-void setelah sheet pembayaran
      // dibuka sehingga total di widget sudah kedaluwarsa (insiden order 094).
      final paymentSnapshot =
          ConnectivityService.instance.online.value && localOutbox == null
          ? await OrdersDatasource().fetchPaymentSnapshot(widget.order.id)
          : OrderPaymentSnapshot(
              totalAmount: widget.order.totalAmount,
              paidTotal: widget.order.paidTotal,
              status: widget.order.status.value,
            );
      if (paymentSnapshot.status == 'paid' ||
          paymentSnapshot.remaining <= 0.01) {
        if (!mounted) return;
        // Tampilkan toast & refresh SEBELUM pop (context masih hidup).
        AppToast.error(context, 'Order ini sudah dibayar.');
        widget.bloc.add(OrdersRefreshRequested());
        Navigator.pop(context);
        if (widget.popUnderlying) Navigator.pop(context);
        return;
      }

      final displayedRemaining = _total;
      final totalChanged =
          (paymentSnapshot.totalAmount - widget.order.totalAmount).abs() > 0.01;
      final paidChanged =
          (paymentSnapshot.paidTotal - widget.order.paidTotal).abs() > 0.01;
      if (totalChanged || paidChanged) {
        if (!mounted) return;
        AppToast.error(
          context,
          'Tagihan berubah dari ${CurrencyFormatter.format(displayedRemaining)} '
          'menjadi ${CurrencyFormatter.format(paymentSnapshot.remaining)}. '
          'Daftar order diperbarui; buka pembayaran kembali.',
        );
        widget.bloc.add(OrdersRefreshRequested());
        Navigator.pop(context);
        if (widget.popUnderlying) Navigator.pop(context);
        return;
      }
      final payableAmount = paymentSnapshot.remaining;

      // Seluruh metode membawa shift penerima. Tunai mengisi laci fisik;
      // nontunai tetap perlu shift supaya laporan kasir tidak bolong.
      String? tillShiftId;
      if (authState is AuthAuthenticated && mounted) {
        // ShiftBloc sudah dimuat saat shell kasir dibuka. Pakai data ini lebih
        // dulu agar tombol Bayar tidak bergantung pada round-trip Wi-Fi.
        // Dialog berada di root Navigator, sedangkan ShiftBloc hidup di
        // ShellRoute kasir. Gunakan referensi yang ditangkap sebelum dialog
        // dibuka; membaca dari BuildContext dialog akan ProviderNotFound.
        final activeShift = widget.shiftBloc.state.activeShift;
        if (activeShift?.kasirId == authState.profile.id &&
            activeShift?.outletId == outletId) {
          tillShiftId = activeShift!.id;
        } else {
          final res = await resolveCashTill(
            context,
            outletId: outletId,
            sellerId: authState.profile.id,
            fromCache: true,
            isCash: _isCash,
            requireOwnShift: authState.profile.role == UserRole.kasir,
          );
          if (res.outcome == TillOutcome.cancelled) {
            if (mounted) setState(() => _processing = false);
            return;
          }
          tillShiftId = res.shiftId;
        }
        if (tillShiftId == null) {
          if (mounted) {
            setState(() => _processing = false);
            AppToast.error(
              context,
              'Pembayaran memerlukan shift kasir terbuka.',
            );
          }
          return;
        }
      }

      final expectedUserId = authState is AuthAuthenticated
          ? authState.profile.id
          : null;
      final signature =
          '${widget.order.id}|${_method.value}|$payableAmount|$tillShiftId';
      final journal = TransactionJournalService.instance;
      final operationId =
          _paymentJournalSignature == signature && _paymentJournalId != null
          ? _paymentJournalId!
          : 'existing-payment-${const Uuid().v4()}';
      final idempotencyKey =
          _paymentJournalSignature == signature &&
              _paymentIdempotencyKey != null
          ? _paymentIdempotencyKey!
          : const Uuid().v4();
      final existingJournal = journal.get(operationId);
      final paidAt =
          localOutbox?['paidAt'] as String? ??
          (existingJournal?['payload'] as Map?)?['paidAt'] as String? ??
          ConnectivityService.instance.trustedUtcNow().toIso8601String();
      var queuedOffline = false;
      if (localOutbox != null) {
        // Order belum pernah sampai server. Satukan pembayaran ke payload
        // induk supaya replay create+pay tetap atomik dan tidak mempunyai
        // jurnal anak yang dapat mendahului pembuatan header order.
        final updated = await OfflineQueueService.instance
            .updateByClientOrderId(widget.order.id, {
              'kind': 'paid',
              'shiftId': tillShiftId,
              'paymentMethod': _method.value,
              'amount': payableAmount,
              'idempotencyKey': idempotencyKey,
              'paidAt': paidAt,
              'paidAtClockSource':
                  ConnectivityService.instance.hasTrustedServerClock
                  ? 'server_offset'
                  : 'device',
            });
        if (updated == null) {
          throw StateError('Order lokal tidak ditemukan di antrean aman');
        }
        await OrdersDatasource().cacheQueuedOrder(updated);
        queuedOffline = true;
      } else {
        if (existingJournal == null) {
          await journal.enqueue(
            id: operationId,
            type: 'existing_payment',
            payload: {
              'orderId': widget.order.id,
              'outletId': outletId,
              'method': _method.value,
              'amount': payableAmount,
              'shiftId': tillShiftId,
              'expectedUserId': expectedUserId,
              'idempotencyKey': idempotencyKey,
              'paidAt': paidAt,
              'paidAtClockSource':
                  ConnectivityService.instance.hasTrustedServerClock
                  ? 'server_offset'
                  : 'device',
            },
          );
        }
        _paymentJournalId = operationId;
        _paymentJournalSignature = signature;
        _paymentIdempotencyKey = idempotencyKey;
        await journal.markSending(operationId);
        if (!ConnectivityService.instance.online.value) {
          await journal.markPending(operationId);
          queuedOffline = true;
        } else {
          try {
            await OrdersDatasource().processPayment(
              orderId: widget.order.id,
              outletId: outletId,
              method: _method,
              amount: payableAmount,
              tillShiftId: tillShiftId,
              expectedUserId: expectedUserId,
              idempotencyKey: idempotencyKey,
              paidAt: paidAt,
            );
            await journal.remove(operationId);
            _paymentJournalId = null;
            _paymentJournalSignature = null;
            _paymentIdempotencyKey = null;
          } catch (error) {
            if (isBackendTransportFailure(error)) {
              await journal.markPending(operationId, error);
              queuedOffline = true;
            } else {
              await journal.markNeedsReview(operationId, error);
              rethrow;
            }
          }
        }
      }

      if (queuedOffline) {
        unawaited(SyncService.instance.sync());
        final ordersDatasource = OrdersDatasource();
        await ordersDatasource.applyCachedPayment(
          outletId: outletId,
          orderId: widget.order.id,
          paymentId: idempotencyKey,
          method: _method,
          amount: payableAmount,
          paidAt: paidAt,
          finalize: true,
        );
        await ordersDatasource.setCachedTableStatus(
          outletId: outletId,
          tableId: widget.order.tableId,
          status: 'available',
        );
      }

      // Tiket dapur didahulukan agar proses produksi tidak tertahan oleh
      // koneksi printer struk. Kegagalan cetak tidak boleh membatalkan
      // pembayaran yang sudah sah tersimpan di server.
      try {
        if (queuedOffline) {
          if (!widget.order.kitchenPrinted) {
            await printKitchenTicketsForLocalOrder(
              order: widget.order,
              categoryNames: PosDatasource().cachedCategoryNames(outletId),
              trigger: KitchenTrigger.bayar,
              printedBy: cashierName,
            );
          }
        } else {
          await printKitchenTicketsForOrder(
            orderId: widget.order.id,
            outletId: outletId,
            trigger: KitchenTrigger.bayar,
            printedBy: cashierName,
            skipIfAlreadyPrinted: true,
            claimBeforePrint: true,
          );
        }
      } catch (error, stack) {
        await ErrorLogService.report(error, stack);
        if (mounted) {
          AppToast.error(
            context,
            'Tiket dapur belum tercetak. Buka order → Cetak Tiket Dapur.',
          );
        }
      }

      // ── Cetak struk (popup connect jika belum terhubung) ──────────
      if (mounted) {
        await _tryPrintReceipt(
          context: context,
          order: widget.order,
          outletId: outletId,
          method: _method,
          cashReceived: _isCash ? _received : null,
          cashierName: cashierName,
        );
      }

      widget.bloc.add(OrdersRefreshRequested());

      if (!mounted) return;
      // Tutup payment sheet (+ detail sheet). Simpan root navigator dulu — context
      // sheet mati setelah pop, jadi dialog sukses pakai context root navigator
      // (cegah assertion lifecycle / "deactivated ancestor").
      final rootNavigator = Navigator.of(context, rootNavigator: true);
      Navigator.pop(context);
      if (widget.popUnderlying) Navigator.pop(context);

      // Tampilkan sukses (struk)
      showPaymentSuccess(
        rootNavigator.context,
        orderNumber: widget.order.orderNumber,
        customerName: widget.order.customerName,
        orderType: widget.order.orderType,
        subtotal: widget.order.subtotal,
        tax: widget.order.taxAmount,
        service: widget.order.serviceCharge,
        total: widget.order.totalAmount,
        kembalian: _isCash ? _kembalian : 0,
        offline: queuedOffline,
      );
    } catch (e, stack) {
      if (!mounted) return;
      setState(() => _processing = false);
      unawaited(ErrorLogService.report(e, stack));
      AppToast.error(
        context,
        humanizeError(e, fallback: 'Pembayaran gagal diproses.'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 600;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Header ──────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(
            children: [
              const Text(
                'Pembayaran',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(6),
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        // ── Content ─────────────────────────────────────────────
        Expanded(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: _infoPane(),
                      ),
                    ),
                    const VerticalDivider(width: 1, color: AppColors.border),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: _payPane(),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _infoPane(),
                      const Divider(height: 28),
                      _payPane(),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ── Kiri: info pelanggan + rincian transaksi ────────────────────────────────
  Widget _infoPane() {
    final o = widget.order;
    final color = _statusMeta(_displayOrderStatus(o)).$1;
    final items = o.items ?? const <OrderItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Info Pelanggan',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: color.withValues(alpha: 0.18),
              child: Text(
                _avatarText(o),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.customerName ?? 'Tanpa Pelanggan',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    'Order #${o.orderNumber} · ${_orderTypeLabel(o)}',
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
              _fmtDate(o.createdAt),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const Divider(height: 24),
        const Text(
          'Rincian Transaksi',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${i.quantity}x ',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                Expanded(child: Text(i.menuItem?.name ?? '-')),
                Text(CurrencyFormatter.format(i.subtotal)),
              ],
            ),
          ),
        const Divider(height: 24),
        _amountRow('Subtotal', o.subtotal),
        if (o.discountAmount > 0)
          _amountRow('Diskon', -o.discountAmount, color: AppColors.secondary),
        if (o.taxAmount > 0) _amountRow('Pajak', o.taxAmount),
        if (o.serviceCharge > 0) _amountRow('Service', o.serviceCharge),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Total',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              CurrencyFormatter.format(_total),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _amountRow(String label, double value, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        Text(
          CurrencyFormatter.format(value),
          style: TextStyle(fontSize: 13, color: color),
        ),
      ],
    ),
  );

  // ── Kanan: metode + nominal + numpad + bayar ─────────────────────────────────
  Widget _payPane() {
    final display = _isCash ? _received : _total;
    final methods = _methods
        .where((m) => _enabledMethods.contains(m.$1.value))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pilih Metode Pembayaran',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 10),
        _MethodDropdown(
          value: _method,
          methods: methods,
          onChanged: (v) => setState(() {
            _method = v;
            _input = '';
          }),
        ),
        const SizedBox(height: 16),
        // Nominal besar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          alignment: Alignment.center,
          child: Column(
            children: [
              Text(
                _isCash ? 'Uang Diterima' : 'Jumlah Bayar',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                CurrencyFormatter.format(display),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_isCash && _input.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _kembalian >= 0
                      ? 'Kembalian ${CurrencyFormatter.format(_kembalian)}'
                      : 'Kurang ${CurrencyFormatter.format(_kembalian.abs())}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _kembalian >= 0
                        ? AppColors.secondary
                        : AppColors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_isCash) ...[
          _QuickCash(
            total: _total,
            onSelect: (v) => setState(() => _input = v.toStringAsFixed(0)),
          ),
          const SizedBox(height: 12),
          _Numpad(onKey: _onNumpad),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _canPay ? _confirmPayment : null,
            icon: _processing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_circle),
            label: Text(
              _processing ? 'Memproses...' : 'Bayar Sekarang',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton.icon(
            onPressed: _processing ? null : _openSplit,
            icon: const Icon(Icons.call_split, size: 18),
            label: const Text('Bagi Tagihan'),
          ),
        ),
      ],
    );
  }

  void _openSplit() {
    final auth = context.read<AuthBloc>().state;
    final outletId = auth is AuthAuthenticated
        ? auth.profile.outletId ?? ''
        : '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SplitBillSheet(
        order: widget.order,
        outletId: outletId,
        bloc: widget.bloc,
      ),
    );
  }
}

// ── Dropdown metode pembayaran (gaya custom: menu rounded + item terpilih) ────
class _MethodDropdown extends StatelessWidget {
  final PaymentMethod value;
  final List<(PaymentMethod, IconData, String)> methods;
  final ValueChanged<PaymentMethod> onChanged;
  const _MethodDropdown({
    required this.value,
    required this.methods,
    required this.onChanged,
  });

  (PaymentMethod, IconData, String) get _cur =>
      methods.firstWhere((m) => m.$1 == value, orElse: () => methods.first);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return MenuAnchor(
          crossAxisUnconstrained: false,
          style: MenuStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.white),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
            elevation: const WidgetStatePropertyAll(6),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.6),
                ),
              ),
            ),
            minimumSize: WidgetStatePropertyAll(Size(w, 0)),
            maximumSize: WidgetStatePropertyAll(Size(w, 420)),
          ),
          builder: (context, controller, _) {
            final open = controller.isOpen;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => open ? controller.close() : controller.open(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: open ? AppColors.primary : AppColors.border,
                    width: open ? 1.6 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(_cur.$2, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _cur.$3,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      open
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            );
          },
          menuChildren: [
            for (final m in methods)
              _MethodMenuItem(
                width: w - 16,
                icon: m.$2,
                label: m.$3,
                selected: m.$1 == value,
                onTap: () => onChanged(m.$1),
              ),
          ],
        );
      },
    );
  }
}

class _MethodMenuItem extends StatelessWidget {
  final double width;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _MethodMenuItem({
    required this.width,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.textPrimary;
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(
          selected ? AppColors.accent : Colors.white,
        ),
        overlayColor: const WidgetStatePropertyAll(AppColors.surfaceVariant),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        minimumSize: WidgetStatePropertyAll(Size(width, 46)),
        maximumSize: WidgetStatePropertyAll(Size(width, 46)),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: color,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
          if (selected)
            const Icon(Icons.check, size: 18, color: AppColors.primary),
        ],
      ),
    );
  }
}

class _QuickCash extends StatelessWidget {
  final double total;
  final ValueChanged<double> onSelect;
  const _QuickCash({required this.total, required this.onSelect});

  static double _roundUp(double v, double to) => (v / to).ceil() * to;

  @override
  Widget build(BuildContext context) {
    final amounts = {
      _roundUp(total, 5000),
      _roundUp(total, 10000),
      _roundUp(total, 20000),
      _roundUp(total, 50000),
    }.toList()..sort();
    return Row(
      children: amounts
          .take(4)
          .map(
            (a) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: GestureDetector(
                  onTap: () => onSelect(a),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.teal,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      CurrencyFormatter.format(a),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _Numpad extends StatelessWidget {
  final ValueChanged<String> onKey;
  const _Numpad({required this.onKey});

  static const _keys = [
    '7',
    '8',
    '9',
    '4',
    '5',
    '6',
    '1',
    '2',
    '3',
    '000',
    '0',
    '⌫',
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 2.0,
      children: _keys.map((k) {
        final isDel = k == '⌫';
        return GestureDetector(
          onTap: () => onKey(k),
          child: Container(
            decoration: BoxDecoration(
              color: isDel
                  ? AppColors.error.withValues(alpha: 0.08)
                  : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDel
                    ? AppColors.error.withValues(alpha: 0.25)
                    : AppColors.border,
              ),
            ),
            child: Center(
              child: isDel
                  ? const Icon(
                      Icons.backspace_outlined,
                      color: AppColors.error,
                      size: 20,
                    )
                  : Text(
                      k,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

(Color, String) _statusMeta(OrderStatus status) => switch (status) {
  OrderStatus.draft => (AppColors.statusDraft, 'Draft'),
  OrderStatus.confirmed => (AppColors.statusConfirmed, 'Dikonfirmasi'),
  OrderStatus.preparing => (AppColors.statusPreparing, 'Dimasak'),
  OrderStatus.ready => (AppColors.statusReady, 'Siap'),
  OrderStatus.served => (AppColors.statusServed, 'Disajikan'),
  OrderStatus.paid => (AppColors.statusPaid, 'Lunas'),
  OrderStatus.cancelled => (AppColors.statusCancelled, 'Batal'),
  OrderStatus.void_ => (AppColors.statusVoid, 'Void'),
};

IconData _statusIcon(OrderStatus status) => switch (status) {
  OrderStatus.draft => Icons.edit_note_rounded,
  OrderStatus.confirmed => Icons.schedule_rounded,
  OrderStatus.preparing => Icons.local_fire_department_rounded,
  OrderStatus.ready => Icons.check_circle_rounded,
  OrderStatus.served => Icons.room_service_rounded,
  OrderStatus.paid => Icons.verified_rounded,
  OrderStatus.cancelled => Icons.cancel_rounded,
  OrderStatus.void_ => Icons.block_rounded,
};

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = _statusMeta(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon(status), size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Auto-print struk helper ────────────────────────────────────────────────────────
// Jika printer belum terhubung, tampilkan popup agar user bisa connect dulu.
// Jika user memilih "Lewati", cetak struk dilewati (transaksi tetap berhasil).

Future<void> _tryPrintReceipt({
  required BuildContext context,
  required Order order,
  required String outletId,
  PaymentMethod? method,
  double? cashReceived,
  Map<PaymentMethod, double> paymentBreakdown = const {},
  String? cashierName,
}) async {
  if (outletId.isEmpty) return;
  if (!PrinterService.isSupported) return;
  try {
    final printer = PrinterService();
    // Printer LAN tak punya konsep "terhubung" — jangan gerbangi dengan BT.
    if (await printer.receiptNeedsBluetoothConnect() && !printer.isConnected) {
      final autoOk = await printer.tryAutoReconnect();
      if (!autoOk) {
        if (!context.mounted) return;
        final connected = await showPrinterConnectDialog(context);
        if (!connected) return; // user pilih "Lewati"
      }
    }

    final datasource = PosDatasource();
    Map<String, dynamic>? outletData = datasource.cachedOutletReceiptMap(
      outletId,
    );
    if (ConnectivityService.instance.online.value) {
      try {
        outletData = await datasource.fetchOutletReceiptMap(outletId);
      } catch (_) {
        // Snapshot terakhir cukup untuk cetak saat server baru saja putus.
      }
    }
    if (outletData == null) {
      throw StateError('Data struk outlet belum pernah diunduh');
    }

    final info = OutletReceiptInfo.fromMap(outletData);
    // Batas cetak: bila aktif & struk order ini sudah pernah dicetak → lewati.
    if (info.receipt.limitPrint &&
        await printer.receiptAlreadyPrinted(order.id)) {
      return;
    }
    // Ukuran kertas HARUS ikut printer struknya. Tanpa ini semua cetak ulang
    // dibangun 58mm — di printer 80mm hasilnya melenceng.
    final rcpt = await printer.printerForReceipt();
    final paper = rcpt?.paper == '80' ? PaperSize.mm80 : PaperSize.mm58;
    final builder = ReceiptBuilder(
      outlet: info,
      paperSize: paper,
      driver: rcpt?.driver ?? 'generic1',
    );
    final bytes = await builder.build(
      order: order,
      paymentMethod: method,
      cashReceived: cashReceived,
      paymentBreakdown: paymentBreakdown,
      cashierName: cashierName,
      customerName: order.customerName,
      waiterName: cashierName,
    );
    // Pembayaran biasa maupun split memakai trigger autoprint yang sama dan
    // menghormati toggle "Autoprint Bayar" pada printer Struk.
    final outcome = await printer.printReceiptBytes(bytes, auto: true);
    if (outcome.isPrinted && info.receipt.limitPrint) {
      await printer.markReceiptPrinted(order.id);
    }
    if (!outcome.isPrinted && context.mounted) {
      AppToast.error(
        context,
        outcome.isFailed
            ? 'Struk gagal dicetak. Periksa printer di Pengaturan → Perangkat.'
            : 'Tidak ada printer dengan peran Struk. Atur di Pengaturan → Perangkat.',
      );
    }
  } catch (_) {
    // Cetak best-effort, tapi jangan telan diam-diam: ini SATU-SATUNYA jalur
    // cetak ulang, dan pesan error di halaman bayar menyuruh kasir ke sini.
    if (context.mounted) {
      AppToast.error(context, 'Struk gagal dicetak. Coba lagi.');
    }
  }
}

/// Muat ulang order setelah split difinalisasi supaya struk membawa seluruh
/// metode pembayaran, termasuk split yang sudah dicatat sebelum sheet dibuka.
/// Jalur ini dipakai bersama oleh order tersimpan dan order QR per meja.
Future<void> _tryPrintFinalizedSplitReceipt({
  required BuildContext context,
  required String orderId,
  required String outletId,
  String? cashierName,
}) async {
  try {
    final orderData = await Supabase.instance.client
        .from('orders')
        .select(
          '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price)), payments(method, amount)',
        )
        .eq('id', orderId)
        .single();
    final order = Order.fromJson(orderData);
    final paymentBreakdown = receiptPaymentBreakdown(
      order.payments ?? const [],
    );
    if (!context.mounted) return;
    await _tryPrintReceipt(
      context: context,
      order: order,
      outletId: outletId,
      paymentBreakdown: paymentBreakdown,
      cashierName: cashierName,
    );
  } catch (_) {
    if (context.mounted) {
      AppToast.error(context, 'Struk gagal dicetak. Coba cetak ulang.');
    }
  }
}

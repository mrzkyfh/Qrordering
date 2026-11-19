import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:uuid/uuid.dart';
import '../bloc/pos_bloc.dart';
import 'stored_item_void_notice.dart';
import '../../domain/entities/cart_item.dart';
import '../../data/datasources/pos_datasource.dart';
import '../../../../shared/models/enums.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/printer_service.dart';
import 'print_target_sheet.dart';
import '../../../../shared/services/offline_queue_service.dart';
import '../../../../shared/services/sync_service.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../../../shared/widgets/backend_network_image.dart';
import '../../../../shared/models/order.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../domain/entities/held_order.dart';
import '../../data/services/held_order_service.dart';
import '../../../orders/data/datasources/orders_datasource.dart';

/// Kontrak open-bill: hasil append dari server adalah satu-satunya daftar yang
/// boleh diteruskan ke tiket dapur. Order lama tidak pernah menjadi input
/// callback cetak ini.
Future<List<OrderItem>> appendAndPrintNewOrderItems({
  required Future<List<OrderItem>> Function() append,
  required Future<void> Function(List<OrderItem> items) print,
}) async {
  final newItems = await append();
  await print(newItems);
  return newItems;
}

// ── Warna pastel per kategori (sinkron dengan menu_item_card) ─────────────────
Color _catBg(String? category) {
  if (category == null) return const Color(0xFFF5F5F5);
  final c = category.toLowerCase();
  if (c.contains('dessert')) return const Color(0xFFE8F5E9);
  if (c.contains('snack')) return const Color(0xFFFFF3E0);
  if (c.contains('burger')) return const Color(0xFFFCE4EC);
  if (c.contains('sup') || c.contains('soto')) return const Color(0xFFE3F2FD);
  if (c.contains('ayam') || c.contains('bebek')) return const Color(0xFFF1F8E9);
  if (c.contains('minum') || c.contains('kopi') || c.contains('teh')) {
    return const Color(0xFFE8EAF6);
  }
  return const Color(0xFFF5F5F5);
}

/// Dekorasi field input cart — seragam (spec: r10, #F5F5F5, tanpa border,
/// prefix 16/#BBB, hint 12/#CCC, contentPadding v0/h12). Tinggi 44px diatur
/// oleh SizedBox pembungkus.
InputDecoration _cartFieldDecoration({
  required IconData icon,
  required String hint,
}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
  prefixIcon: Icon(icon, size: 16, color: const Color(0xFFBBBBBB)),
  prefixIconConstraints: const BoxConstraints(minWidth: 40),
  // Tanpa isDense + contentPadding vertikal 0 → field mengisi penuh
  // SizedBox(44) (pill tinggi konsisten dengan tombol Cari/Pakai).
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
  filled: true,
  fillColor: const Color(0xFFF5F5F5),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide.none,
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide.none,
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.2),
  ),
);

// ─────────────────────────────────────────────────────────────────────────────
// CART PANEL
// ─────────────────────────────────────────────────────────────────────────────

class CartPanel extends StatefulWidget {
  const CartPanel({super.key});

  @override
  State<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<CartPanel> {
  String? _busyAction;

  bool get _isBusy => _busyAction != null;

  Future<void> _runAction(
    String action,
    Future<void> Function() operation,
  ) async {
    if (_isBusy) return;
    setState(() => _busyAction = action);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  String _actionLabel(String action, String normal, String processing) =>
      _busyAction == action ? processing : normal;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildPanel);

  Widget _buildPanel(BuildContext context, BoxConstraints constraints) {
    return BlocBuilder<PosBloc, PosState>(
      builder: (context, state) {
        final itemCount = state.itemCount;

        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              left: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
            ),
          ),
          child: Column(
            children: [
              // ── 1. Header ────────────────────────────────────
              Container(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.of(context).padding.top + 12,
                  16,
                  12,
                ),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(
                            Icons.shopping_cart_outlined,
                            size: 18,
                            color: Color(0xFF111111),
                          ),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Pesanan',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF111111),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (itemCount > 0) ...[
                      Tooltip(
                        message: 'Kosongkan Keranjang',
                        child: SizedBox(
                          key: const Key('clear-cart-button'),
                          width: 40,
                          height: 40,
                          child: IconButton(
                            onPressed: _isBusy
                                ? null
                                : () => _confirmClearCart(context),
                            style: IconButton.styleFrom(
                              foregroundColor: const Color(0xFFB42318),
                              backgroundColor: const Color(0xFFFFEEEE),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              side: const BorderSide(
                                color: Color(0xFFF2A7A3),
                                width: 1,
                              ),
                            ),
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.delete_sweep_outlined,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    _HeldOrdersButton(outletId: state.loadedOutletId),
                    if (itemCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF5F5),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: const Color(0xFFFCCACA),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '$itemCount item',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── 2. Tipe order / penanda mode order lama ──────────
              if (state.replaceOrderId != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF8E7),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFF3D58A), width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.edit_note,
                        size: 18,
                        color: Color(0xFF8A5A00),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mengedit pesanan online #${state.replaceOrderNumber ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8A5A00),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else if (state.appendOrderId != null)
                Container(
                  key: const Key('append-order-mode-banner'),
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF3E8),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFF2C89B), width: 1),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.add_shopping_cart,
                          size: 18,
                          color: Color(0xFF9A4F00),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TAMBAH KE PESANAN #${state.appendOrderNumber ?? ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF7A3E00),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_appendOrderTypeLabel(state.orderType)}${state.tableNumber?.trim().isNotEmpty == true ? ' · Meja ${state.tableNumber}' : ''}\nItem bukan transaksi baru dan akan masuk ke pesanan ini.',
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: Color(0xFF7A3E00),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        key: const Key('exit-append-order-button'),
                        onPressed: _isBusy
                            ? null
                            : () => _confirmExitAppendMode(context, state),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFB42318),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text(
                          'Keluar',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
                    ),
                  ),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        _TypeTab(
                          label: 'Dine In',
                          selected: state.orderType == OrderType.dineIn,
                          onTap: () => context.read<PosBloc>().add(
                            PosOrderTypeChanged(OrderType.dineIn),
                          ),
                        ),
                        _TypeTab(
                          label: 'Takeaway',
                          selected: state.orderType == OrderType.takeaway,
                          onTap: () => context.read<PosBloc>().add(
                            PosOrderTypeChanged(OrderType.takeaway),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Pilih meja (Dine In only) ─────────────────────
              if (state.appendOrderId == null &&
                  state.orderType == OrderType.dineIn)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: GestureDetector(
                    onTap: () => context.push('/kasir/tables'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: state.tableId != null
                              ? const Color(0xFF0F766E)
                              : const Color(0xFFEFEFEF),
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.table_restaurant_outlined,
                            size: 16,
                            color: state.tableId != null
                                ? const Color(0xFF0F766E)
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            state.tableNumber != null
                                ? 'Meja ${state.tableNumber}'
                                : 'Pilih meja',
                            style: TextStyle(
                              fontSize: 13,
                              color: state.tableId != null
                                  ? const Color(0xFF0F766E)
                                  : AppColors.textSecondary,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: state.tableId != null
                                ? const Color(0xFF0F766E)
                                : AppColors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // ── 3. List item — SATU-SATUNYA yang scroll ─────────
              Expanded(
                child: state.cart.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        key: const Key('cart-item-list'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: state.cart.length,
                        itemBuilder: (context, i) {
                          final item = state.cart[i];
                          final isLast = i == state.cart.length - 1;
                          return Slidable(
                                key: ValueKey(item.id),
                                endActionPane: ActionPane(
                                  motion: const DrawerMotion(),
                                  extentRatio: 0.25,
                                  children: [
                                    SlidableAction(
                                      onPressed: (_) {
                                        if (item.requiresVoidToRemove) {
                                          showStoredItemVoidNotice(context);
                                          return;
                                        }
                                        context.read<PosBloc>().add(
                                          PosItemRemoved(item.id),
                                        );
                                      },
                                      backgroundColor: AppColors.error,
                                      foregroundColor: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      icon: Icons.delete_outline,
                                      label: 'Hapus',
                                    ),
                                  ],
                                ),
                                child: _CartItemRow(item: item, isLast: isLast),
                              )
                              .animate()
                              .fadeIn(duration: 200.ms)
                              .slideX(
                                begin: 0.08,
                                end: 0,
                                curve: Curves.easeOut,
                              );
                        },
                      ),
              ),

              // ── 4. Kontrol bawah ─────────────────────────────────────
              // Dibatasi maksimal 55% tinggi panel dan dapat digulir. Dengan
              // begitu daftar produk selalu mendapat ruang yang cukup pada
              // tablet landscape maupun browser berjendela pendek.
              if (state.cart.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    // Reserve room for the header and cart items in short windows.
                    maxHeight: (constraints.maxHeight - 250).clamp(
                      0.0,
                      constraints.maxHeight * 0.55,
                    ),
                  ),
                  child: SingleChildScrollView(
                    key: const Key('cart-footer-scroll'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 1. Input: nama, member, voucher
                        if (state.appendOrderId == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _CustomerNameInput(),
                                const SizedBox(height: 4),
                                _LoyaltyInput(
                                  outletId: state.cart.first.menuItem.outletId,
                                ),
                                const SizedBox(height: 4),
                                _PromoInput(
                                  outletId: state.cart.first.menuItem.outletId,
                                ),
                              ],
                            ),
                          ),

                        // 2. Breakdown + Total — satu card
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8F8F8),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFEFEFEF),
                              width: 0.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              _SummaryRow(
                                'Subtotal',
                                CurrencyFormatter.format(state.subtotal),
                              ),
                              if (state.taxAmount > 0)
                                _SummaryRow(
                                  'Pajak (${state.taxPercent.toStringAsFixed(0)}%)',
                                  CurrencyFormatter.format(state.taxAmount),
                                ),
                              if (state.serviceCharge > 0)
                                _SummaryRow(
                                  'Service (${state.serviceChargePercent.toStringAsFixed(0)}%)',
                                  CurrencyFormatter.format(state.serviceCharge),
                                ),
                              if (state.discountAmount > 0)
                                _SummaryRow(
                                  'Diskon${state.promoCode != null ? " (${state.promoCode})" : ""}',
                                  '- ${CurrencyFormatter.format(state.discountAmount)}',
                                  valueColor: const Color(0xFF1D9E75),
                                ),
                              if (state.loyaltyDiscount > 0)
                                _SummaryRow(
                                  'Tukar Poin (${state.redeemedPoints} pt)',
                                  '- ${CurrencyFormatter.format(state.loyaltyDiscount)}',
                                  valueColor: const Color(0xFF1D9E75),
                                ),
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  color: Color(0xFFE5E5E5),
                                ),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Total',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF111111),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        CurrencyFormatter.format(state.total),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF0F766E),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // 3. Tombol Cetak Struk & Bayar (atau Tambah ke Pesanan)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: state.replaceOrderId != null
                              ? SizedBox(
                                  height: 42,
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: _isBusy
                                        ? null
                                        : () => _runAction(
                                            'replace',
                                            () => _replaceOnlineOrder(
                                              context,
                                              state,
                                            ),
                                          ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFC0392B),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.save_outlined,
                                      size: 18,
                                    ),
                                    label: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        _actionLabel(
                                          'replace',
                                          'Simpan Perubahan #${state.replaceOrderNumber ?? ''}',
                                          'Menyimpan...',
                                        ),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : state.appendOrderId != null
                              ? SizedBox(
                                  height: 42,
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: _isBusy
                                        ? null
                                        : () => _runAction(
                                            'append',
                                            () => _appendToExistingOrder(
                                              context,
                                              state,
                                            ),
                                          ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFC0392B),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    icon: const Icon(Icons.add, size: 18),
                                    label: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        _actionLabel(
                                          'append',
                                          'Tambah ke Pesanan #${state.appendOrderNumber ?? ''}',
                                          'Menambahkan...',
                                        ),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        height: 42,
                                        child: OutlinedButton(
                                          onPressed: _isBusy
                                              ? null
                                              : () => _runAction(
                                                  'print',
                                                  () => _cetakStruk(
                                                    context,
                                                    state,
                                                  ),
                                                ),
                                          style: OutlinedButton.styleFrom(
                                            backgroundColor: Colors.white,
                                            foregroundColor: const Color(
                                              0xFF444444,
                                            ),
                                            side: const BorderSide(
                                              color: Color(0xFFDDDDDD),
                                              width: 1.5,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          child: Text(
                                            _actionLabel(
                                              'print',
                                              'Cetak Struk',
                                              'Memproses...',
                                            ),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w500,
                                              fontSize: 14,
                                              color: Color(0xFF444444),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: SizedBox(
                                        height: 42,
                                        child: FilledButton(
                                          onPressed: _isBusy
                                              ? null
                                              : () => context.push(
                                                  '/kasir/payment',
                                                ),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFFC0392B,
                                            ),
                                            disabledBackgroundColor:
                                                const Color(0xFFE0E0E0),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          child: const Text(
                                            'Bayar',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),

                        // 4. Simpan ke Daftar Order
                        if (state.appendOrderId == null &&
                            state.replaceOrderId == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: OutlinedButton.icon(
                                onPressed: _isBusy
                                    ? null
                                    : () => _runAction(
                                        'save',
                                        () => _simpanKeDaftarOrder(
                                          context,
                                          state,
                                        ),
                                      ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF0F766E),
                                  backgroundColor: const Color(0xFFFFF5F5),
                                  side: const BorderSide(
                                    color: Color(0xFFFCCACA),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                icon: const Icon(Icons.playlist_add, size: 16),
                                label: Text(
                                  _actionLabel(
                                    'save',
                                    'Simpan ke Daftar Order',
                                    'Menyimpan...',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Parked order: belum menjadi draft server dan belum masuk
                        // laporan. Dipakai untuk melayani pelanggan berikutnya.
                        if (state.appendOrderId == null &&
                            state.replaceOrderId == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: OutlinedButton.icon(
                                onPressed: _isBusy
                                    ? null
                                    : () => _runAction(
                                        'hold',
                                        () => _tahanPesanan(context, state),
                                      ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF55708F),
                                  backgroundColor: const Color(0xFFF7F9FC),
                                  side: const BorderSide(
                                    color: Color(0xFFD9E2F0),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.pause_circle_outline,
                                  size: 16,
                                ),
                                label: Text(
                                  _actionLabel(
                                    'hold',
                                    'Tahan Pesanan',
                                    'Menyimpan...',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(
            Icons.shopping_cart_outlined,
            size: 36,
            color: Color(0xFFDDDDDD),
          ),
          SizedBox(height: 10),
          Text(
            'Belum ada item',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFFBBBBBB),
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Tap menu untuk menambahkan',
            style: TextStyle(fontSize: 11, color: Color(0xFFCCCCCC)),
          ),
        ],
      ),
    );
  }

  void _confirmClearCart(BuildContext context) {
    if (context.read<PosBloc>().state.cart.any(
      (item) => item.requiresVoidToRemove,
    )) {
      showStoredItemVoidNotice(context);
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          'Kosongkan Keranjang?',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Semua item akan dihapus dari pesanan.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<PosBloc>().add(PosCartRemovalRequested());
            },
            child: const Text(
              'Kosongkan',
              style: TextStyle(color: Color(0xFF0F766E)),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmExitAppendMode(BuildContext context, PosState state) {
    void exitMode() => context.read<PosBloc>().add(PosAppendCancelled());

    if (state.cart.isEmpty) {
      exitMode();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          'Keluar dari Tambah Pesanan?',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Item yang belum disimpan tidak akan masuk ke pesanan '
          '#${state.appendOrderNumber ?? ''}. Setelah keluar, aplikasi akan '
          'memulai transaksi baru tanpa meja.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Tetap di Sini'),
          ),
          FilledButton(
            key: const Key('confirm-exit-append-order-button'),
            onPressed: () {
              Navigator.pop(dialogContext);
              exitMode();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC0392B),
            ),
            child: const Text('Mulai Pesanan Baru'),
          ),
        ],
      ),
    );
  }
}

String _appendOrderTypeLabel(OrderType type) => switch (type) {
  OrderType.selfOrder => 'Pesanan QR',
  OrderType.dineIn => 'Dine In',
  OrderType.takeaway => 'Bawa Pulang',
};

// ──────────────────────────────────────────────────────────────────────────────
// BUSINESS LOGIC — tidak diubah sama sekali
// ──────────────────────────────────────────────────────────────────────────────

// Simpan transaksi ke Daftar Order sebagai DRAF (belum kirim dapur, belum
// bayar). Kasir bisa buka lagi nanti untuk lanjut/bayar. Tanpa cetak.
Future<void> _simpanKeDaftarOrder(BuildContext context, PosState state) async {
  if (state.cart.isEmpty) return;
  final auth = context.read<AuthBloc>().state;
  if (auth is! AuthAuthenticated) return;
  final posBloc = context.read<PosBloc>();
  final router = GoRouter.of(context);
  final outletId = auth.profile.outletId ?? '';

  if (!ConnectivityService.instance.online.value) {
    await _enqueueDraftOffline(state, auth);
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    AppToast.success(
      context,
      'Offline — disimpan sebagai draf, tersinkron ke Daftar Order saat online.',
    );
    router.go('/kasir/orders');
    return;
  }

  if (!await _ensureCartCatalogCurrent(context, state, outletId)) return;

  try {
    await PosDatasource().createOrder(
      outletId: outletId,
      cart: state.cart,
      orderType: state.orderType,
      tableId: state.tableId,
      discountAmount: state.discountAmount,
      taxAmount: state.taxAmount,
      serviceCharge: state.serviceCharge,
      taxInclusive: state.taxInclusiveForOrder,
      rounding: state.rounding,
      createdBy: auth.profile.id,
      customerName: state.customerName,
      loyaltyMemberId: state.loyaltyMemberId,
      loyaltyDiscount: state.loyaltyDiscount,
      redeemedPoints: state.redeemedPoints,
      promoId: state.promoId,
      voucherId: state.voucherId,
      status: 'draft',
      clientOrderId: state.transactionRequestId,
    );
    await _removeReplacedDraft(state.editingOrderId);
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    AppToast.success(context, 'Transaksi disimpan ke Daftar Order.');
    router.go('/kasir/orders');
  } catch (e) {
    final stillOnline = await ConnectivityService.instance.recheck();
    if (!stillOnline) {
      await _enqueueDraftOffline(state, auth);
      posBloc.add(PosCartCleared());
      if (!context.mounted) return;
      AppToast.success(context, 'Offline — disimpan sebagai draf.');
      router.go('/kasir/orders');
      return;
    }
    if (!context.mounted) return;
    AppToast.error(
      context,
      humanizeError(e, fallback: 'Gagal menyimpan transaksi.'),
    );
  }
}

Future<void> _tahanPesanan(BuildContext context, PosState state) async {
  if (state.cart.isEmpty) return;
  if (state.cart.any((item) => item.requiresVoidToRemove)) {
    AppToast.error(
      context,
      'Pesanan tersimpan tidak dapat dijadikan keranjang lokal. Selesaikan edit melalui Daftar Order.',
    );
    return;
  }
  final auth = context.read<AuthBloc>().state;
  if (auth is! AuthAuthenticated) return;
  final initialLabel = state.customerName?.trim().isNotEmpty == true
      ? state.customerName!
      : state.tableNumber != null
      ? 'Meja ${state.tableNumber}'
      : '';
  final label = await showDialog<String>(
    context: context,
    builder: (_) => _HoldOrderDialog(initialLabel: initialLabel),
  );
  if (label == null || !context.mounted) return;

  final outletId = auth.profile.outletId ?? state.loadedOutletId;
  if (outletId.isEmpty) {
    AppToast.error(context, 'Outlet belum dipilih.');
    return;
  }
  try {
    await HeldOrderService.save(
      outletId: outletId,
      items: state.cart,
      orderType: state.orderType,
      tableId: state.tableId,
      tableNumber: state.tableNumber,
      customerName: state.customerName,
      label: label,
    );
    if (!context.mounted) return;
    context.read<PosBloc>().add(PosCartCleared());
    AppToast.success(context, 'Pesanan ditahan. Bisa dilanjutkan kapan saja.');
  } catch (_) {
    if (context.mounted) AppToast.error(context, 'Pesanan gagal ditahan.');
  }
}

class _HoldOrderDialog extends StatefulWidget {
  final String initialLabel;
  const _HoldOrderDialog({required this.initialLabel});

  @override
  State<_HoldOrderDialog> createState() => _HoldOrderDialogState();
}

class _HoldOrderDialogState extends State<_HoldOrderDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialLabel);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tahan Pesanan'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Nama/label pesanan',
          hintText: 'Contoh: Budi atau Meja 4',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Tahan')),
      ],
    );
  }
}

class _HeldOrdersButton extends StatelessWidget {
  final String outletId;
  const _HeldOrdersButton({required this.outletId});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: IconButton(
      tooltip: 'Pesanan ditahan',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: outletId.isEmpty
          ? null
          : () => _showHeldOrders(context, outletId),
      icon: const Icon(
        Icons.pause_circle_outline,
        size: 20,
        color: Color(0xFF55708F),
      ),
    ),
  );
}

Future<void> _showHeldOrders(BuildContext context, String outletId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _HeldOrdersSheet(outletId: outletId),
  );
}

class _HeldOrdersSheet extends StatefulWidget {
  final String outletId;
  const _HeldOrdersSheet({required this.outletId});

  @override
  State<_HeldOrdersSheet> createState() => _HeldOrdersSheetState();
}

class _HeldOrdersSheetState extends State<_HeldOrdersSheet> {
  late Future<List<HeldOrder>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = HeldOrderService.list(widget.outletId);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FutureBuilder<List<HeldOrder>>(
          future: _future,
          builder: (context, snapshot) {
            final orders = snapshot.data ?? const <HeldOrder>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pesanan Ditahan',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Belum masuk Daftar Order dan belum mengurangi stok.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (orders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(child: Text('Belum ada pesanan ditahan.')),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: orders.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final order = orders[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFFEAF0F7),
                            child: Icon(Icons.pause, color: Color(0xFF55708F)),
                          ),
                          title: Text(
                            order.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${order.items.fold<int>(0, (s, i) => s + i.quantity)} item · ${_formatHeldTime(order.createdAt)}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'ambil') {
                                await _restore(order);
                              } else {
                                await HeldOrderService.remove(order.id);
                                if (mounted) setState(_reload);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'ambil',
                                child: Text('Lanjutkan'),
                              ),
                              PopupMenuItem(
                                value: 'hapus',
                                child: Text('Hapus'),
                              ),
                            ],
                          ),
                          onTap: () => _restore(order),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _restore(HeldOrder order) async {
    final pos = context.read<PosBloc>();
    if (pos.state.cart.isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Ganti pesanan aktif?'),
          content: const Text(
            'Keranjang saat ini akan diganti dengan pesanan yang ditahan.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Ganti'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    pos.add(
      PosCartLoaded(
        order.items,
        orderType: order.orderType,
        tableId: order.tableId,
        tableNumber: order.tableNumber,
        customerName: order.customerName,
      ),
    );
    await HeldOrderService.remove(order.id);
    if (!mounted) return;
    Navigator.pop(context);
    AppToast.success(context, 'Pesanan ${order.label} dilanjutkan.');
  }
}

String _formatHeldTime(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

// Buat order (masuk antrian dapur) lalu tampilkan pilihan tujuan cetak
// (Struk Kasir / Tiket Dapur). Menggantikan aksi lama "Ke Dapur".
Future<void> _cetakStruk(BuildContext context, PosState state) async {
  if (state.cart.isEmpty) return;
  final auth = context.read<AuthBloc>().state;
  if (auth is! AuthAuthenticated) return;
  final posBloc = context.read<PosBloc>();
  final router = GoRouter.of(context);

  if (!ConnectivityService.instance.online.value) {
    final localOrderId = await _enqueueDraftOffline(
      state,
      auth,
      confirmed: true,
    );
    final printResult = await _printOfflineKitchenOrder(
      state: state,
      orderId: localOrderId,
      outletId: auth.profile.outletId ?? '',
      printedBy: auth.profile.fullName,
    );
    await _rememberOfflineKitchenResult(localOrderId, printResult);
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    AppToast.success(
      context,
      'Offline — pesanan tersimpan dan tiket dapur sudah diproses.',
    );
    router.go('/kasir/orders');
    return;
  }

  final outletId = auth.profile.outletId ?? '';
  if (!await _ensureCartCatalogCurrent(context, state, outletId)) return;

  try {
    final orderId = await PosDatasource().createOrder(
      outletId: outletId,
      cart: state.cart,
      orderType: state.orderType,
      tableId: state.tableId,
      discountAmount: state.discountAmount,
      taxAmount: state.taxAmount,
      serviceCharge: state.serviceCharge,
      taxInclusive: state.taxInclusiveForOrder,
      rounding: state.rounding,
      createdBy: auth.profile.id,
      customerName: state.customerName,
      loyaltyMemberId: state.loyaltyMemberId,
      loyaltyDiscount: state.loyaltyDiscount,
      redeemedPoints: state.redeemedPoints,
      promoId: state.promoId,
      voucherId: state.voucherId,
      status: 'confirmed',
      clientOrderId: state.transactionRequestId,
    );
    await _removeReplacedDraft(state.editingOrderId);
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    // Pilih tujuan cetak: Struk Kasir dan/atau Tiket Dapur.
    await showPrintTargetSheet(
      context,
      orderId: orderId,
      outletId: outletId,
      cashierName: auth.profile.fullName,
    );
    if (!context.mounted) return;
    router.go('/kasir/orders');
  } catch (e) {
    final stillOnline = await ConnectivityService.instance.recheck();
    if (!stillOnline) {
      final localOrderId = await _enqueueDraftOffline(
        state,
        auth,
        confirmed: true,
      );
      final printResult = await _printOfflineKitchenOrder(
        state: state,
        orderId: localOrderId,
        outletId: auth.profile.outletId ?? '',
        printedBy: auth.profile.fullName,
      );
      await _rememberOfflineKitchenResult(localOrderId, printResult);
      posBloc.add(PosCartCleared());
      if (!context.mounted) return;
      AppToast.success(
        context,
        'Offline — pesanan tersimpan dan tiket dapur sudah diproses.',
      );
      router.go('/kasir/orders');
      return;
    }
    if (!context.mounted) return;
    AppToast.error(
      context,
      humanizeError(e, fallback: 'Gagal mengirim ke dapur.'),
    );
  }
}

Future<bool> _ensureCartCatalogCurrent(
  BuildContext context,
  PosState state,
  String outletId,
) async {
  try {
    final result = await PosDatasource().reconcileCartWithServer(
      outletId,
      state.cart,
    );
    if (!result.changed && !result.blocking) return true;
    if (!context.mounted) return false;
    context.read<PosBloc>().add(PosCatalogReconciled(result));
    final detail = result.messages.take(3).join('. ');
    AppToast.error(
      context,
      result.blocking
          ? 'Katalog berubah: $detail. Periksa keranjang.'
          : 'Harga terbaru sudah diterapkan: $detail. Periksa total lalu ulangi.',
    );
    return false;
  } catch (error) {
    if (isBackendTransportFailure(error)) return true;
    if (context.mounted) {
      AppToast.error(
        context,
        humanizeError(
          error,
          fallback: 'Katalog terbaru belum dapat diverifikasi.',
        ),
      );
    }
    return false;
  }
}

Future<void> _appendToExistingOrder(
  BuildContext context,
  PosState state,
) async {
  if (state.cart.isEmpty || state.appendOrderId == null) return;
  final auth = context.read<AuthBloc>().state;
  if (auth is! AuthAuthenticated) return;
  final posBloc = context.read<PosBloc>();
  final router = GoRouter.of(context);
  final outletId = auth.profile.outletId ?? '';
  final orderId = state.appendOrderId!;

  if (!ConnectivityService.instance.online.value) {
    await _queueOfflineAppend(
      state: state,
      orderId: orderId,
      outletId: outletId,
      expectedUserId: auth.profile.id,
      printedBy: auth.profile.fullName,
    );
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    AppToast.success(
      context,
      'Offline — item tambahan disimpan dan akan tersinkron otomatis.',
    );
    router.go('/kasir/orders');
    return;
  }

  if (!await _ensureCartCatalogCurrent(context, state, outletId)) return;

  try {
    await appendAndPrintNewOrderItems(
      append: () => PosDatasource().addItemsToExistingOrderAtomic(
        orderId: orderId,
        newItems: state.cart,
        taxPercent: state.taxPercent,
        taxActive: state.taxActive,
        serviceChargePercent: state.serviceChargePercent,
        requestId: state.transactionRequestId,
      ),
      print: (newItems) async {
        await printKitchenTicketsForNewItems(
          orderId: orderId,
          outletId: outletId,
          items: newItems,
          printedBy: auth.profile.fullName,
        );
      },
    );
    posBloc.add(PosCartCleared());
    if (!context.mounted) return;
    AppToast.success(context, 'Pesanan ditambahkan & dikirim ke dapur.');
    // Alert proaktif: bahan yang baru menipis akibat item tambahan.
    final lowStock = await PosDatasource().lowStockAfterOrder(orderId);
    if (context.mounted && lowStock.isNotEmpty) {
      AppToast.error(
        context,
        'Stok menipis: ${lowStock.take(3).join(', ')}${lowStock.length > 3 ? ', +${lowStock.length - 3} lainnya' : ''}',
        title: 'Segera restock',
      );
    }
    router.go('/kasir/orders');
  } catch (e) {
    if (!context.mounted) return;
    AppToast.error(
      context,
      humanizeError(e, fallback: 'Gagal menambah pesanan.'),
    );
  }
}

Future<void> _queueOfflineAppend({
  required PosState state,
  required String orderId,
  required String outletId,
  required String expectedUserId,
  String? printedBy,
}) async {
  final requestId = state.transactionRequestId ?? const Uuid().v4();
  final itemPayload = [
    for (final item in state.cart)
      {
        'menu_item_id': item.menuItem.id,
        'quantity': item.quantity,
        'unit_price': item.unitPrice,
        'notes': item.notes,
        'extras': [
          for (final extra in item.selectedExtras)
            {'menu_extra_option_id': extra.menuExtraOptionId},
        ],
      },
  ];
  final updatedLocalParent = await PosDatasource().appendItemsToQueuedOrder(
    outletId: outletId,
    orderId: orderId,
    items: state.cart,
    taxPercent: state.taxPercent,
    taxActive: state.taxActive,
    taxInclusive: state.taxInclusiveForOrder,
    serviceChargePercent: state.serviceChargePercent,
    roundingIncrement: state.rounding,
  );
  final appendedToLocalParent = updatedLocalParent != null;
  if (updatedLocalParent != null) {
    final updated = updatedLocalParent;
    await OrdersDatasource().cacheQueuedOrder(updated);
  } else {
    await TransactionJournalService.instance.enqueue(
      id: requestId,
      type: 'append_order_items',
      payload: {
        'orderId': orderId,
        'outletId': outletId,
        'expectedUserId': expectedUserId,
        'requestId': requestId,
        'taxPercent': state.taxPercent,
        'taxActive': state.taxActive,
        'serviceChargePercent': state.serviceChargePercent,
        'items': itemPayload,
      },
    );
    await PosDatasource().appendItemsToCachedOrder(
      outletId: outletId,
      orderId: orderId,
      items: state.cart,
      taxPercent: state.taxPercent,
      taxActive: state.taxActive,
      taxInclusive: state.taxInclusiveForOrder,
      serviceChargePercent: state.serviceChargePercent,
      roundingIncrement: state.rounding,
    );
  }

  final now = DateTime.now();
  final localItems = [
    for (final item in state.cart)
      OrderItem(
        id: const Uuid().v4(),
        orderId: orderId,
        menuItemId: item.menuItem.id,
        quantity: item.quantity,
        unitPrice: item.unitPrice,
        subtotal: item.subtotal,
        notes: item.notes,
        menuItem: item.menuItem,
        options: [
          for (final extra in item.selectedExtras)
            OrderItemOption(
              extraName: extra.extraName,
              optionName: extra.optionName,
              price: extra.price,
            ),
        ],
      ),
  ];
  final printResult = await printKitchenTicketsForLocalOrder(
    order: Order(
      id: orderId,
      outletId: outletId,
      orderNumber: state.appendOrderNumber ?? orderId,
      orderType: state.orderType,
      status: OrderStatus.confirmed,
      subtotal: localItems.fold(0, (sum, item) => sum + item.subtotal),
      discountAmount: 0,
      taxAmount: 0,
      serviceCharge: 0,
      totalAmount: localItems.fold(0, (sum, item) => sum + item.subtotal),
      stockDeducted: false,
      createdAt: now,
      updatedAt: now,
      tableId: state.tableId,
      tableNumber: state.tableNumber,
      items: localItems,
    ),
    categoryNames: PosDatasource().cachedCategoryNames(outletId),
    trigger: KitchenTrigger.order,
    printedBy: printedBy,
    printedAt: now,
  );
  if (appendedToLocalParent) {
    final appendHandled =
        printResult.hasPrinted ||
        printResult.hasQueued ||
        printResult.skippedReason == 'Semua kategori sengaja tidak dicetak';
    final updated = await OfflineQueueService.instance.updateByClientOrderId(
      orderId,
      {
        // Klaim server hanya boleh menandai SELURUH order sudah dicetak bila
        // batch awal dan batch tambahan sama-sama aman di printer/antrean.
        'localKitchenPrinted':
            updatedLocalParent['localKitchenPrinted'] == true && appendHandled,
      },
    );
    if (updated != null) await OrdersDatasource().cacheQueuedOrder(updated);
  }
  SyncService.instance.sync();
}

Future<void> _replaceOnlineOrder(BuildContext context, PosState state) async {
  final orderId = state.replaceOrderId;
  if (state.cart.isEmpty || orderId == null) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Simpan Perubahan?'),
      content: Text(
        'Item pesanan online #${state.replaceOrderNumber ?? ''} akan diganti '
        'dengan isi keranjang saat ini. Nomor pesanan tetap sama.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Simpan'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final auth = context.read<AuthBloc>().state;
  if (auth is! AuthAuthenticated) return;
  if (!ConnectivityService.instance.online.value) {
    await _queueOfflineOnlineOrderReplacement(state, auth, orderId);
    if (!context.mounted) return;
    context.read<PosBloc>().add(PosCartCleared());
    AppToast.success(
      context,
      'Perubahan pesanan tersimpan offline dan akan disinkronkan.',
    );
    GoRouter.of(context).go('/kasir/orders');
    return;
  }

  try {
    await PosDatasource().replaceOnlineOrderItems(
      orderId: orderId,
      items: state.cart,
      customerName: state.customerName,
    );
    if (!context.mounted) return;
    context.read<PosBloc>().add(PosCartCleared());
    AppToast.success(
      context,
      'Pesanan online #${state.replaceOrderNumber ?? ''} berhasil diperbarui.',
    );
    GoRouter.of(context).go('/kasir/orders');
  } catch (e) {
    if (isBackendTransportFailure(e)) {
      await _queueOfflineOnlineOrderReplacement(state, auth, orderId);
      if (!context.mounted) return;
      context.read<PosBloc>().add(PosCartCleared());
      AppToast.success(
        context,
        'Perubahan pesanan tersimpan offline dan akan disinkronkan.',
      );
      GoRouter.of(context).go('/kasir/orders');
      return;
    }
    if (!context.mounted) return;
    AppToast.error(
      context,
      humanizeError(e, fallback: 'Gagal memperbarui pesanan online.'),
    );
  }
}

Future<void> _queueOfflineOnlineOrderReplacement(
  PosState state,
  AuthAuthenticated auth,
  String orderId,
) async {
  final outletId = auth.profile.outletId ?? '';
  final operationId =
      'replace-${state.transactionRequestId ?? const Uuid().v4()}';
  final items = [
    for (final item in state.cart)
      {
        'menu_item_id': item.menuItem.id,
        'quantity': item.quantity,
        'unit_price': item.unitPrice,
        'notes': item.notes,
        'extras': [
          for (final extra in item.selectedExtras)
            {'menu_extra_option_id': extra.menuExtraOptionId},
        ],
      },
  ];
  await TransactionJournalService.instance.enqueue(
    id: operationId,
    type: 'replace_online_order_items',
    payload: {
      'orderId': orderId,
      'outletId': outletId,
      'expectedUserId': auth.profile.id,
      'items': items,
      'customerName': state.customerName,
    },
  );
  await PosDatasource().replaceCachedOrderItems(
    outletId: outletId,
    orderId: orderId,
    items: state.cart,
    customerName: state.customerName,
    subtotal: state.subtotal,
    discountAmount: state.discountAmount,
    taxAmount: state.taxAmount,
    serviceCharge: state.serviceCharge,
    totalAmount: state.total,
  );
  SyncService.instance.sync();
}

Future<String> _enqueueDraftOffline(
  PosState state,
  AuthAuthenticated auth, {
  bool confirmed = false,
}) async {
  const uuid = Uuid();
  final clientOrderId = state.transactionRequestId ?? uuid.v4();
  final outletId = auth.profile.outletId ?? '';
  final shiftId = PosDatasource().cachedOwnShiftId(outletId, auth.profile.id);
  final payload = <String, dynamic>{
    'kind': confirmed ? 'confirmed' : 'draft',
    'clientOrderId': clientOrderId,
    'outletId': outletId,
    'createdBy': auth.profile.id,
    'shiftId': shiftId,
    'orderType': state.orderType.value,
    'tableId': state.tableId,
    'customerName': state.customerName,
    'subtotal': state.subtotal,
    'discountAmount': state.discountAmount,
    'taxAmount': state.taxAmount,
    'serviceCharge': state.serviceCharge,
    'taxInclusive': state.taxInclusiveForOrder,
    'rounding': state.rounding,
    'loyaltyMemberId': state.loyaltyMemberId,
    'loyaltyDiscount': state.loyaltyDiscount,
    'redeemedPoints': state.redeemedPoints,
    'promoId': state.promoId,
    'voucherId': state.voucherId,
    'localKitchenPrinted': false,
    'total': state.total,
    'clockSource': ConnectivityService.instance.hasTrustedServerClock
        ? 'server_offset'
        : 'device',
    // Instan UTC — nilai ini dikirim ke kolom timestamptz saat replay sync.
    'createdAt': ConnectivityService.instance.trustedUtcNow().toIso8601String(),
    // Draf lama sengaja tidak dihapus saat masuk mode edit. Hapus setelah
    // transaksi pengganti berhasil tersinkron di server.
    'replacesOrderId': state.editingOrderId,
    'items': state.cart
        .map(
          (item) => {
            'menuItemId': item.menuItem.id,
            'name': item.menuItem.name,
            'quantity': item.quantity,
            'unitPrice': item.unitPrice,
            'subtotal': item.subtotal,
            'notes': item.notes,
            'extras': item.selectedExtras
                .map(
                  (e) => {
                    'menuExtraId': e.menuExtraId,
                    'menuExtraOptionId': e.menuExtraOptionId,
                    'extraName': e.extraName,
                    'optionName': e.optionName,
                    'price': e.price,
                  },
                )
                .toList(),
          },
        )
        .toList(),
  };
  await OfflineQueueService.instance.enqueue(payload);
  await OrdersDatasource().cacheQueuedOrder(payload);
  await OrdersDatasource().setCachedTableStatus(
    outletId: outletId,
    tableId: state.tableId,
    status: 'occupied',
  );
  SyncService.instance.sync();
  return clientOrderId;
}

Future<KitchenPrintResult> _printOfflineKitchenOrder({
  required PosState state,
  required String orderId,
  required String outletId,
  String? printedBy,
}) async {
  final now = DateTime.now();
  final items = [
    for (final item in state.cart)
      OrderItem(
        id: const Uuid().v4(),
        orderId: orderId,
        menuItemId: item.menuItem.id,
        quantity: item.quantity,
        unitPrice: item.unitPrice,
        subtotal: item.subtotal,
        notes: item.notes,
        menuItem: item.menuItem,
        options: [
          for (final extra in item.selectedExtras)
            OrderItemOption(
              extraName: extra.extraName,
              optionName: extra.optionName,
              price: extra.price,
            ),
        ],
      ),
  ];
  return printKitchenTicketsForLocalOrder(
    order: Order(
      id: orderId,
      outletId: outletId,
      orderNumber: 'OFFLINE',
      orderType: state.orderType,
      status: OrderStatus.confirmed,
      customerName: state.customerName,
      subtotal: state.subtotal,
      discountAmount: state.discountAmount,
      taxAmount: state.taxAmount,
      serviceCharge: state.serviceCharge,
      totalAmount: state.total,
      stockDeducted: false,
      createdAt: now,
      updatedAt: now,
      tableId: state.tableId,
      tableNumber: state.tableNumber,
      items: items,
    ),
    categoryNames: PosDatasource().cachedCategoryNames(outletId),
    trigger: KitchenTrigger.order,
    printedBy: printedBy,
    printedAt: now,
  );
}

Future<void> _rememberOfflineKitchenResult(
  String orderId,
  KitchenPrintResult result,
) async {
  final handled =
      result.hasPrinted ||
      result.hasQueued ||
      result.skippedReason == 'Semua kategori sengaja tidak dicetak';
  if (!handled) return;
  final deviceId = await PrinterService().devicePrintId();
  final updated = await OfflineQueueService.instance.updateByClientOrderId(
    orderId,
    {'localKitchenPrinted': true, 'kitchenPrintDeviceId': deviceId},
  );
  if (updated != null) await OrdersDatasource().cacheQueuedOrder(updated);
}

/// Bersihkan draf lama hanya setelah order pengganti berhasil dibuat.
/// Kegagalan cleanup tidak boleh menghapus/membatalkan order baru.
Future<void> _removeReplacedDraft(String? orderId) async {
  if (orderId == null || orderId.isEmpty) return;
  try {
    await OrdersDatasource().deleteOrder(orderId);
  } catch (_) {
    // Order baru tetap sah. Draf lama dapat dibersihkan manual oleh kasir.
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// UI WIDGETS
// ──────────────────────────────────────────────────────────────────────────────

class _TypeTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TypeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: double.infinity,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF111111)
                    : const Color(0xFF888888),
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CartItemRow extends StatelessWidget {
  final CartItem item;
  final bool isLast;
  const _CartItemRow({required this.item, required this.isLast});

  void _onMinusTap(BuildContext context) {
    if (item.requiresVoidToDecrease) {
      showStoredItemVoidNotice(context);
      return;
    }
    if (item.quantity == 1) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Text(
            'Hapus ${item.menuItem.name}?',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          content: Text(
            'Hapus ${item.menuItem.name} dari pesanan?',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.read<PosBloc>().add(PosItemRemoved(item.id));
              },
              child: const Text(
                'Hapus',
                style: TextStyle(color: Color(0xFF0F766E)),
              ),
            ),
          ],
        ),
      );
    } else {
      context.read<PosBloc>().add(PosQuantityChanged(item.id, -1));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: isLast
          ? null
          : const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFF5F5F5), width: 0.5),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 34,
              height: 34,
              child: ColoredBox(
                color: _catBg(item.menuItem.categoryName),
                child: item.menuItem.imageUrl != null
                    ? BackendNetworkImage(
                        imageUrl: item.menuItem.imageUrl!,
                        fit: BoxFit.cover,
                        width: 34,
                        height: 34,
                        memCacheWidth: 96,
                        memCacheHeight: 96,
                        placeholderBuilder: (ctx) => const SizedBox.shrink(),
                        errorBuilder: (ctx) => const Center(
                          child: Icon(
                            Icons.restaurant,
                            size: 16,
                            color: Color(0xFFCCCCCC),
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(
                          Icons.restaurant,
                          size: 16,
                          color: Color(0xFFCCCCCC),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.menuItem.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111111),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.selectedVariant != null)
                  Text(
                    item.selectedVariant!.name,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                if (item.selectedExtras.isNotEmpty)
                  Text(
                    item.selectedExtras.map((e) => e.optionName).join(', '),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 1),
                Text(
                  CurrencyFormatter.format(item.unitPrice),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF0F766E),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Qty controls
          Row(
            children: [
              _QtyBtn(
                onTap: () => _onMinusTap(context),
                icon: Icons.remove,
                isMinus: true,
              ),
              SizedBox(
                width: 20,
                child: Text(
                  '${item.quantity}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Color(0xFF111111),
                  ),
                ),
              ),
              _QtyBtn(
                onTap: () =>
                    context.read<PosBloc>().add(PosQuantityChanged(item.id, 1)),
                icon: Icons.add,
                isMinus: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final bool isMinus;
  const _QtyBtn({
    required this.onTap,
    required this.icon,
    required this.isMinus,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        tooltip: isMinus ? 'Kurangi jumlah' : 'Tambah jumlah',
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        style: IconButton.styleFrom(
          foregroundColor: isMinus ? const Color(0xFF0F766E) : Colors.white,
          backgroundColor: isMinus
              ? const Color(0xFFFFECEC)
              : const Color(0xFF0F766E),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(icon, size: 17),
      ),
    );
  }
}

// ── Input nama pelanggan ───────────────────────────────────────────────────────

class _CustomerNameInput extends StatefulWidget {
  const _CustomerNameInput();

  @override
  State<_CustomerNameInput> createState() => _CustomerNameInputState();
}

class _CustomerNameInputState extends State<_CustomerNameInput> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: context.read<PosBloc>().state.customerName ?? '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _ctrl,
        textCapitalization: TextCapitalization.words,
        style: const TextStyle(fontSize: 12, color: Color(0xFF111111)),
        onChanged: (v) =>
            context.read<PosBloc>().add(PosCustomerNameChanged(v)),
        decoration: _cartFieldDecoration(
          icon: Icons.badge_outlined,
          hint: 'Nama pelanggan (opsional)...',
        ),
      ),
    );
  }
}

// ── Loyalty / member input ─────────────────────────────────────────────────────

class _LoyaltyInput extends StatefulWidget {
  final String outletId;
  const _LoyaltyInput({required this.outletId});

  @override
  State<_LoyaltyInput> createState() => _LoyaltyInputState();
}

class _LoyaltyInputState extends State<_LoyaltyInput> {
  final _ctrl = TextEditingController();
  final _redeemCtrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    _redeemCtrl.dispose();
    super.dispose();
  }

  static InputDecoration _inputDec({
    required IconData icon,
    required String hint,
  }) => _cartFieldDecoration(icon: icon, hint: hint);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosBloc>().state;
    final hasMember = s.loyaltyMemberId != null;
    final isLoading = s.loyaltyLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _ctrl,
                  enabled: !hasMember && !isLoading,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF111111),
                  ),
                  decoration: _inputDec(
                    icon: Icons.person_outline,
                    hint: hasMember
                        ? '${s.loyaltyMemberPhone}'
                        : 'No HP Member (opsional)',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: hasMember
                  ? OutlinedButton(
                      onPressed: () {
                        _ctrl.clear();
                        context.read<PosBloc>().add(PosLoyaltyCleared());
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF0F766E)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: const Text(
                        'Hapus',
                        style: TextStyle(
                          color: Color(0xFF0F766E),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  : FilledButton(
                      onPressed: isLoading
                          ? null
                          : () {
                              if (_ctrl.text.trim().isEmpty) return;
                              context.read<PosBloc>().add(
                                PosLoyaltyLookup(
                                  _ctrl.text.trim(),
                                  outletId: widget.outletId,
                                ),
                              );
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Cari',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                    ),
            ),
          ],
        ),
        if (s.loyaltyError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _ErrorChip(label: 'Member tidak ditemukan'),
          ),
        if (hasMember) ...[
          const SizedBox(height: 4),
          _SuccessChip(
            label:
                '${s.loyaltyMemberName ?? "-"} · ${s.loyaltyMemberPoints} poin',
            onRemove: () {
              _ctrl.clear();
              context.read<PosBloc>().add(PosLoyaltyCleared());
            },
          ),
          // Redeem subform
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _redeemCtrl,
                    enabled: !s.redeemLoading && s.loyaltyDiscount == 0,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 11),
                    decoration: InputDecoration(
                      hintText: s.loyaltyDiscount > 0
                          ? '${s.redeemedPoints} poin terpakai'
                          : 'Tukar poin...',
                      hintStyle: const TextStyle(fontSize: 11),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFAFAFA),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Color(0xFFEFEFEF),
                          width: 1,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Color(0xFFEFEFEF),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 32,
                child: s.loyaltyDiscount > 0
                    ? OutlinedButton(
                        onPressed: () {
                          _redeemCtrl.clear();
                          context.read<PosBloc>().add(
                            PosLoyaltyRedeemCleared(),
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.error),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: const Text(
                          'Batal',
                          style: TextStyle(
                            color: AppColors.error,
                            fontSize: 11,
                          ),
                        ),
                      )
                    : FilledButton(
                        onPressed: s.redeemLoading
                            ? null
                            : () {
                                final pts =
                                    int.tryParse(_redeemCtrl.text.trim()) ?? 0;
                                if (pts > 0) {
                                  context.read<PosBloc>().add(
                                    PosLoyaltyRedeem(pts),
                                  );
                                }
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.success,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: s.redeemLoading
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Tukar',
                                style: TextStyle(fontSize: 11),
                              ),
                      ),
              ),
            ],
          ),
          if (s.redeemError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ErrorChip(label: s.redeemError!),
            ),
          if (s.loyaltyDiscount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _SuccessChip(
                label:
                    'Poin ditukar · diskon ${CurrencyFormatter.format(s.loyaltyDiscount)}',
                onRemove: () {
                  _redeemCtrl.clear();
                  context.read<PosBloc>().add(PosLoyaltyRedeemCleared());
                },
              ),
            ),
        ],
      ],
    );
  }
}

// ── Promo input ───────────────────────────────────────────────────────────────

class _PromoInput extends StatefulWidget {
  final String outletId;
  const _PromoInput({required this.outletId});

  @override
  State<_PromoInput> createState() => _PromoInputState();
}

class _PromoInputState extends State<_PromoInput> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosBloc>().state;
    final hasPromo = s.promoCode != null;
    final isLoading = s.promoLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _ctrl,
                  enabled: !hasPromo && !isLoading,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF111111),
                  ),
                  decoration: _cartFieldDecoration(
                    icon: Icons.local_offer_outlined,
                    hint: hasPromo
                        ? (s.promoCode ?? 'Kode voucher...')
                        : 'Kode voucher...',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: hasPromo
                  ? OutlinedButton(
                      onPressed: () {
                        _ctrl.clear();
                        context.read<PosBloc>().add(PosPromoRemoved());
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF0F766E)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: const Text(
                        'Hapus',
                        style: TextStyle(
                          color: Color(0xFF0F766E),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  : FilledButton(
                      onPressed: isLoading
                          ? null
                          : () {
                              if (_ctrl.text.trim().isEmpty) return;
                              context.read<PosBloc>().add(
                                PosPromoApplied(
                                  _ctrl.text.trim(),
                                  outletId: widget.outletId,
                                ),
                              );
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF111111),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Pakai',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                    ),
            ),
          ],
        ),
        if (s.promoError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _ErrorChip(label: 'Voucher tidak valid'),
          ),
        if (hasPromo && s.discountAmount > 0) ...[
          const SizedBox(height: 4),
          _SuccessChip(
            label: 'Diskon ${CurrencyFormatter.format(s.discountAmount)}',
            onRemove: () {
              _ctrl.clear();
              context.read<PosBloc>().add(PosPromoRemoved());
            },
          ),
        ],
      ],
    );
  }
}

// ── Chip konfirmasi member/voucher berhasil ────────────────────────────────────

class _SuccessChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _SuccessChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3DE),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 12,
            color: Color(0xFF1D9E75),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Color(0xFF1D9E75)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close, size: 10, color: Color(0xFF1D9E75)),
          ),
        ],
      ),
    );
  }
}

// ── Chip error member/voucher tidak ditemukan ─────────────────────────────────

class _ErrorChip extends StatelessWidget {
  final String label;
  const _ErrorChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFFECEC),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, size: 12, color: Color(0xFF0F766E)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF0F766E),
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Summary row ───────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _SummaryRow(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: valueColor ?? const Color(0xFF555555),
            ),
          ),
        ],
      ),
    );
  }
}

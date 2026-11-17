import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../bloc/pos_bloc.dart';
import '../widgets/till_resolver.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/offline_queue_service.dart';
import '../../../../shared/services/sync_service.dart';
import '../../../../shared/services/staff_authorization_lease.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/order.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show PaperSize;
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/receipt_builder.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/local_receipt_number.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/utils/thousands_formatter.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/widgets/payment_success_dialog.dart';
import '../../../../shared/widgets/printer_connect_dialog.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../data/datasources/pos_datasource.dart';
import '../../../orders/data/datasources/orders_datasource.dart';

class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key});
  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  PaymentMethod _method = PaymentMethod.cash;
  bool _processing = false;
  String _input = '';
  String? _splitOrderRequestId;
  String? _splitOrderCartSignature;

  double get _cashReceived => double.tryParse(_input) ?? 0;

  bool _hasValidStaffAuthorization(
    BuildContext context,
    AuthAuthenticated authState,
  ) {
    if (authState.profile.isActive &&
        StaffAuthorizationLease.isValid(authState.profile.id)) {
      return true;
    }
    context.read<AuthBloc>().add(AuthAuthorizationLeaseExpired());
    AppToast.error(
      context,
      authState.profile.isActive
          ? 'Otorisasi kasir telah berakhir. Hubungkan ke server lalu masuk kembali.'
          : 'Akun staf telah dinonaktifkan.',
    );
    return false;
  }

  @override
  void initState() {
    super.initState();
    // Ambil data outlet/kategori/till SEKARANG, selagi kasir memilih metode &
    // mengetik nominal. Saat Bayar ditekan semuanya sudah di cache lokal,
    // sehingga jalur cetak tak perlu menyentuh jaringan sama sekali.
    // Fire-and-forget: gagal pun tidak apa-apa, tiap pembacaan cache punya
    // penanganan sendiri bila datanya belum ada.
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) {
      unawaited(PosDatasource().warmPrintCaches(auth.profile.outletId ?? ''));
    }
  }

  static const _methods = [
    (PaymentMethod.cash, Icons.money, 'Tunai'),
    (PaymentMethod.qris, Icons.qr_code, 'QRIS'),
    (PaymentMethod.debit, Icons.credit_card, 'Debit'),
    (PaymentMethod.credit, Icons.credit_score, 'Kartu Kredit'),
    (PaymentMethod.ewallet, Icons.account_balance_wallet, 'E-Wallet'),
    (PaymentMethod.transfer, Icons.swap_horiz, 'Transfer'),
  ];

  void _onNumpad(String key, double total) {
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

  /// Baris rincian ringkasan (label kiri, nominal kanan).
  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// Baris add-on (varian/extra) di bawah item: "• {nama}" + "(+Rp x)" opsional.
  Widget _addonLine(String label, double? extraPrice) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Text(
        extraPrice != null
            ? '• $label (+${CurrencyFormatter.format(extraPrice)})'
            : '• $label',
        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final posState = context.watch<PosBloc>().state;
    final total = posState.total;
    final methods = _methods
        .where((m) => posState.enabledPaymentMethods.contains(m.$1.value))
        .toList();
    final isCash = _method == PaymentMethod.cash;
    final kembalian = isCash ? _cashReceived - total : 0.0;
    final canPay =
        !_processing &&
        posState.enabledPaymentMethods.contains(_method.value) &&
        (!isCash || _cashReceived >= total);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'Proses Pembayaran',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (posState.tableNumber != null && posState.tableNumber!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    'Meja ${posState.tableNumber}',
                    style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 700;
          final leftPanel = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Ringkasan order
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ringkasan Order',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const Divider(height: 20),
                    ...posState.cart.map(
                      (item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${item.quantity}',
                                      style: const TextStyle(
                                        color: AppColors.primary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    item.menuItem.name,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  CurrencyFormatter.format(item.subtotal),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            // Varian, extra, catatan — indent sejajar nama.
                            if (item.selectedVariant != null ||
                                item.selectedExtras.isNotEmpty ||
                                (item.notes != null &&
                                    item.notes!.trim().isNotEmpty))
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 34,
                                  top: 3,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (item.selectedVariant != null)
                                      _addonLine(
                                        item.selectedVariant!.name,
                                        item.selectedVariant!.priceAddition > 0
                                            ? item
                                                  .selectedVariant!
                                                  .priceAddition
                                            : null,
                                      ),
                                    ...item.selectedExtras.map(
                                      (e) => _addonLine(
                                        e.optionName,
                                        e.price > 0 ? e.price : null,
                                      ),
                                    ),
                                    if (item.notes != null &&
                                        item.notes!.trim().isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 1),
                                        child: Text(
                                          'Catatan: ${item.notes!.trim()}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontStyle: FontStyle.italic,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 20),
                    _summaryRow(
                      'Subtotal',
                      CurrencyFormatter.format(posState.subtotal),
                    ),
                    if (posState.discountAmount + posState.loyaltyDiscount > 0)
                      _summaryRow(
                        'Diskon',
                        '−${CurrencyFormatter.format(posState.discountAmount + posState.loyaltyDiscount)}',
                      ),
                    if (posState.taxAmount > 0)
                      _summaryRow(
                        'Pajak (${posState.taxPercent.toStringAsFixed(0)}%)',
                        CurrencyFormatter.format(posState.taxAmount),
                      ),
                    if (posState.serviceCharge > 0)
                      _summaryRow(
                        'Service (${posState.serviceChargePercent.toStringAsFixed(0)}%)',
                        CurrencyFormatter.format(posState.serviceCharge),
                      ),
                    const SizedBox(height: 6),
                    const Divider(height: 8),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          CurrencyFormatter.format(total),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Metode pembayaran
              const Text(
                'Metode Pembayaran',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.6,
                children: methods
                    .map(
                      (m) => _MethodCard(
                        method: m.$1,
                        icon: m.$2,
                        label: m.$3,
                        selected: _method == m.$1,
                        onTap: () => setState(() {
                          _method = m.$1;
                          _input = '';
                        }),
                      ),
                    )
                    .toList(),
              ),

              const SizedBox(height: 16),

              // Bagi tagihan (di panel kiri, sesuai desain)
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _processing
                      ? null
                      : () => _openSplit(context, posState),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.call_split, size: 18),
                  label: const Text(
                    'Bagi Tagihan',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
            ],
          );
          final rightPanel = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Display
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Diterima
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Diterima',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isCash && _input.isNotEmpty
                                ? CurrencyFormatter.format(_cashReceived)
                                : isCash
                                ? 'Rp 0'
                                : '-',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 22,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Kembalian
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: !isCash
                            ? AppColors.background
                            : kembalian >= 0
                            ? AppColors.success.withValues(alpha: 0.08)
                            : AppColors.error.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: !isCash
                              ? AppColors.border
                              : kembalian >= 0
                              ? AppColors.success
                              : AppColors.error,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            !isCash
                                ? 'Kembalian'
                                : kembalian >= 0
                                ? 'Kembalian'
                                : 'Kurang',
                            style: TextStyle(
                              color: !isCash
                                  ? AppColors.textSecondary
                                  : kembalian >= 0
                                  ? AppColors.success
                                  : AppColors.error,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isCash && _input.isNotEmpty
                                ? CurrencyFormatter.format(kembalian.abs())
                                : 'Rp 0',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 26,
                              color: !isCash
                                  ? AppColors.textSecondary
                                  : kembalian >= 0
                                  ? AppColors.success
                                  : AppColors.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Nominal cepat
              if (isCash)
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: _QuickCashRow(
                    total: total,
                    onSelect: (v) =>
                        setState(() => _input = v.toStringAsFixed(0)),
                  ),
                ),

              const Divider(height: 1),

              // Numpad
              if (isCash)
                Container(
                  color: AppColors.background,
                  padding: const EdgeInsets.all(12),
                  child: _Numpad(onKey: (k) => _onNumpad(k, total)),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                      'Tidak perlu\nmenghitung kembalian',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),

              // Tombol bayar
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: canPay
                            ? () => _processPayment(context, posState)
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
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
                          _processing
                              ? 'Memproses...'
                              : 'Bayar ${CurrencyFormatter.format(total)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          if (wide) {
            return Row(
              children: [
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: leftPanel,
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 340,
                  child: SingleChildScrollView(child: rightPanel),
                ),
              ],
            );
          }
          // Layar sempit (HP): tumpuk vertikal, semua bisa di-scroll.
          return SingleChildScrollView(
            child: Column(
              children: [
                Padding(padding: const EdgeInsets.all(16), child: leftPanel),
                const Divider(height: 1),
                rightPanel,
              ],
            ),
          );
        },
      ),
    );
  }

  /// Bayar = cetak dulu, sinkron belakangan — SATU jalur untuk online & offline.
  ///
  /// Struk disusun dari data yang sudah ada di layar (keranjang + cache outlet)
  /// dan langsung ditembak ke printer, tanpa menunggu server. Order-nya baru
  /// dikirim ke Supabase di latar belakang lewat antrean lokal.
  ///
  /// Kenapa online juga lewat antrean, bukan tulis langsung ke server:
  /// - satu-satunya cara struk keluar ~0.1 detik (jalur lama menunggu
  ///   get_next_order_number + insert order + insert items + insert payment),
  /// - kalau koneksi mati di tengah transaksi, tidak ada lagi kondisi ambigu
  ///   "order terbuat tapi pembayaran gagal" — antrean yang menuntaskannya,
  /// - satu jalur = satu perilaku yang perlu diuji & dijaga, bukan dua yang
  ///   diam-diam berbeda (dulu jalur offline kehilangan till, poin, & promo).
  Future<void> _processPayment(BuildContext context, PosState posState) async {
    // Guard sinkron, BUKAN sekadar mengandalkan tombol yang non-aktif: `canPay`
    // baru ikut berubah setelah rebuild di frame berikutnya, jadi dua tap dalam
    // satu frame (gampang terjadi di HP yang nge-lag) sama-sama lolos dan
    // pelanggan tertagih dua kali.
    if (_processing) return;
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;
    if (!_hasValidStaffAuthorization(context, authState)) return;

    setState(() => _processing = true);
    final outletId = authState.profile.outletId ?? '';
    final online = ConnectivityService.instance.online.value;

    if (!await _ensureCatalogCurrent(context, posState, outletId, online)) {
      if (mounted) setState(() => _processing = false);
      return;
    }
    if (!context.mounted) return;

    // Shift order — dibaca dari cache yang dihangatkan saat halaman ini dibuka,
    // jadi tanpa jaringan & tidak menunda struk.
    //
    // Tunai: kas masuk laci fisik, jadi till harus tepat. Kasir → shiftnya
    // sendiri; owner/admin (tanpa shift) → pilih till bila >1 terbuka.
    // Non-tunai: tak ada laci yang diisi, tapi order tetap nempel ke shift
    // kasir sendiri agar laporan per-shift tidak bolong (mirror createOrder,
    // yang selalu meresolusi shift untuk metode apa pun).
    final shiftResult = await resolveCashTill(
      context,
      outletId: outletId,
      sellerId: authState.profile.id,
      // Saat server dapat dijangkau, status shift harus diverifikasi langsung.
      // Cache hanya menjadi sumber saat offline/request server gagal.
      fromCache: !online,
      isCash: _method == PaymentMethod.cash,
      requireOwnShift: authState.profile.role == UserRole.kasir,
    );
    if (!context.mounted) return;
    if (shiftResult.outcome == TillOutcome.cancelled) {
      setState(() => _processing = false);
      return;
    }
    final shiftId = shiftResult.shiftId;
    if (shiftId == null) {
      setState(() => _processing = false);
      AppToast.error(context, 'Pembayaran memerlukan shift kasir terbuka.');
      return;
    }

    await _enqueuePayAndPrint(
      context,
      posState,
      authState,
      shiftId: shiftId,
      tillResult: shiftResult,
    );
  }

  Future<bool> _ensureCatalogCurrent(
    BuildContext context,
    PosState state,
    String outletId,
    bool online,
  ) async {
    if (!online) return true;
    try {
      final result = await PosDatasource().reconcileCartWithServer(
        outletId,
        state.cart,
      );
      if (!result.changed && !result.blocking) return true;
      if (context.mounted) {
        context.read<PosBloc>().add(PosCatalogReconciled(result));
        final detail = result.messages.take(3).join('. ');
        AppToast.error(
          context,
          result.blocking
              ? 'Katalog berubah: $detail. Periksa keranjang sebelum membayar.'
              : 'Harga terbaru sudah diterapkan: $detail. Periksa total lalu tekan Bayar kembali.',
        );
        context.go('/kasir');
      }
      return false;
    } catch (error) {
      // Gangguan transport diperlakukan sebagai offline: transaksi tetap
      // tersimpan durable di outbox. Penolakan query/izin tidak boleh lolos.
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

  /// Langkah setelah order lunas (dipakai bayar penuh & bagi tagihan):
  /// klaim promo, redeem/earn loyalty, cetak struk, bersihkan keranjang, sukses.
  Future<void> _afterOrderSettled(
    BuildContext context,
    String orderId,
    PosState posState,
    AuthAuthenticated authState, {
    double kembalian = 0,
    PaymentMethod? printMethod,
    double? printCash,
    Map<PaymentMethod, double> paymentBreakdown = const {},
  }) async {
    // Promo dan redeem loyalty sudah diklaim atomik oleh
    // record_pos_payment/finalize_split_payment sebelum status paid. Di sini
    // hanya award poin setelah pembayaran berhasil.
    if (posState.loyaltyMemberId != null) {
      try {
        await PosDatasource().awardLoyaltyPoints(
          orderId: orderId,
          memberId: posState.loyaltyMemberId!,
        );
      } catch (_) {
        /* non-fatal */
      }
    }
    if (context.mounted) {
      await _tryPrintWalkinReceipt(
        context: context,
        orderId: orderId,
        outletId: authState.profile.outletId ?? '',
        cart: posState,
        method: printMethod ?? _method,
        cashReceived: printCash,
        paymentBreakdown: paymentBreakdown,
        cashierName: authState.profile.fullName,
      );
    }
    // Ambil nomor order untuk struk (best-effort).
    String orderNumber = '';
    try {
      final r = await Supabase.instance.client
          .from('orders')
          .select('order_number')
          .eq('id', orderId)
          .maybeSingle();
      orderNumber = (r?['order_number'] as String?) ?? '';
    } catch (_) {
      /* non-fatal */
    }
    if (!context.mounted) return;
    context.read<PosBloc>().add(PosCartCleared());
    await showPaymentSuccess(
      context,
      orderNumber: orderNumber,
      customerName: posState.customerName,
      orderType: posState.orderType,
      subtotal: posState.subtotal,
      tax: posState.taxAmount,
      service: posState.serviceCharge,
      total: posState.total,
      kembalian: kembalian,
    );
    // Alert proaktif: bahan yang baru menipis akibat order ini.
    final lowStock = await PosDatasource().lowStockAfterOrder(orderId);
    if (context.mounted && lowStock.isNotEmpty) {
      AppToast.error(
        context,
        'Stok menipis: ${lowStock.take(3).join(', ')}${lowStock.length > 3 ? ', +${lowStock.length - 3} lainnya' : ''}',
        title: 'Segera restock',
      );
    }
    if (context.mounted) context.go('/kasir');
  }

  /// Bagi tagihan saat checkout: buat draf agar pembayaran punya order_id,
  /// lalu hapus draf kosong bila kasir menutup split sebelum membayar.
  Future<void> _openSplit(BuildContext context, PosState posState) async {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;
    if (!_hasValidStaffAuthorization(context, authState)) return;
    final online = ConnectivityService.instance.online.value;
    final outletId = authState.profile.outletId ?? '';
    if (!await _ensureCatalogCurrent(context, posState, outletId, online)) {
      return;
    }
    if (!context.mounted) return;
    final cartSignature = [
      ...posState.cart.map(
        (item) =>
            '${item.menuItem.id}:${item.quantity}:${item.unitPrice}:${item.selectedExtras.map((e) => e.menuExtraOptionId).join(',')}',
      ),
      posState.orderType.value,
      posState.tableId ?? '',
      posState.total,
    ].join('|');
    if (_splitOrderCartSignature != cartSignature) {
      _splitOrderCartSignature = cartSignature;
      _splitOrderRequestId = const Uuid().v4();
    }
    final splitOrderRequestId = _splitOrderRequestId ??= const Uuid().v4();
    // Bagi tagihan bisa mengandung porsi tunai → tentukan till dulu (owner/admin
    // tanpa shift + >1 till → pilih). Batal → hentikan.
    final tillRes = await resolveCashTill(
      context,
      outletId: outletId,
      sellerId: authState.profile.id,
      fromCache: !online,
      requireOwnShift: authState.profile.role == UserRole.kasir,
    );
    if (tillRes.outcome == TillOutcome.cancelled) return;
    final shiftOverride = tillRes.shiftId;
    if (shiftOverride == null) {
      if (context.mounted) {
        AppToast.error(context, 'Bagi tagihan memerlukan shift kasir terbuka.');
      }
      return;
    }
    Future<void> openOfflineSplit() async {
      if (!context.mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SplitSheet(
          orderId: splitOrderRequestId,
          outletId: outletId,
          shiftId: shiftOverride,
          expectedUserId: authState.profile.id,
          total: posState.total,
          enabledMethods: posState.enabledPaymentMethods,
          offline: true,
          onFinalized: (paymentBreakdown) async {
            _splitOrderRequestId = null;
            _splitOrderCartSignature = null;
            await _enqueuePayAndPrint(
              context,
              posState,
              authState,
              shiftId: shiftOverride,
              tillResult: tillRes,
              clientOrderId: splitOrderRequestId,
              paymentBreakdown: paymentBreakdown,
            );
          },
        ),
      );
    }

    if (!online) {
      await openOfflineSplit();
      return;
    }
    setState(() => _processing = true);
    late CreatedPosOrder createdOrder;
    try {
      createdOrder = await PosDatasource().createOrderWithServerTotal(
        outletId: outletId,
        cart: posState.cart,
        orderType: posState.orderType,
        tableId: posState.tableId,
        discountAmount: posState.discountAmount,
        taxAmount: posState.taxAmount,
        serviceCharge: posState.serviceCharge,
        taxInclusive: posState.taxInclusiveForOrder,
        rounding: posState.rounding,
        createdBy: authState.profile.id,
        customerName: posState.customerName,
        loyaltyMemberId: posState.loyaltyMemberId,
        loyaltyDiscount: posState.loyaltyDiscount,
        redeemedPoints: posState.redeemedPoints,
        promoId: posState.promoId,
        voucherId: posState.voucherId,
        shiftIdOverride: shiftOverride,
        status: 'draft',
        clientOrderId: splitOrderRequestId,
      );
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _processing = false);
      if (isBackendTransportFailure(e)) {
        AppToast.info(
          context,
          'Server belum terjangkau. Split payment disimpan secara offline.',
        );
        await openOfflineSplit();
        return;
      }
      AppToast.error(
        context,
        humanizeError(e, fallback: 'Gagal membuat order.'),
      );
      return;
    }
    if (!context.mounted) return;
    setState(() => _processing = false);
    final completed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SplitSheet(
        orderId: createdOrder.orderId,
        outletId: outletId,
        shiftId: shiftOverride,
        expectedUserId: authState.profile.id,
        // Pakai total resmi server. Cache pajak/layanan di perangkat dapat
        // tertinggal; memakai posState.total membuat UI menunjukkan sisa Rp0
        // sementara finalize_split_payment masih melihat kekurangan.
        total: createdOrder.totalAmount,
        enabledMethods: posState.enabledPaymentMethods,
        onFinalized: (paymentBreakdown) async {
          await OrdersDatasource().finalizeSplitPayment(createdOrder.orderId);
          // Finalisasi sudah dikonfirmasi server. Hapus jurnal sebelum
          // pekerjaan UI/cetak berikutnya agar kegagalan printer atau widget
          // tidak membuat operasi yang sama dijadwalkan ulang.
          await TransactionJournalService.instance.remove(
            'split-finalize-${createdOrder.orderId}',
          );
          _splitOrderRequestId = null;
          _splitOrderCartSignature = null;
          await _removeReplacedDraft(posState.editingOrderId);
          if (!context.mounted) return;
          await _afterOrderSettled(
            context,
            createdOrder.orderId,
            posState,
            authState,
            paymentBreakdown: paymentBreakdown,
          );
        },
      ),
    );
    if (completed != true && context.mounted) {
      try {
        final paidTotal = await OrdersDatasource().fetchPaidTotal(
          createdOrder.orderId,
        );
        if (paidTotal == 0) {
          await OrdersDatasource().deleteOrder(createdOrder.orderId);
        }
      } catch (_) {
        if (context.mounted) {
          AppToast.error(
            context,
            'Bagi tagihan ditutup, tetapi draf order belum dapat dibersihkan. '
            'Periksa Daftar Order.',
          );
        }
      }
    }
  }

  /// Catat transaksi ke antrean lokal → cetak struk → sinkron di latar belakang.
  Future<void> _enqueuePayAndPrint(
    BuildContext context,
    PosState posState,
    AuthAuthenticated authState, {
    String? shiftId,
    TillResult? tillResult,
    String? clientOrderId,
    Map<PaymentMethod, double> paymentBreakdown = const {},
  }) async {
    if (!_hasValidStaffAuthorization(context, authState)) {
      if (mounted) setState(() => _processing = false);
      return;
    }
    const uuid = Uuid();
    final localOrderId = clientOrderId ?? uuid.v4();
    final outletId = authState.profile.outletId ?? '';
    final shiftSnapshot =
        tillResult?.snapshot ??
        (shiftId == null
            ? null
            : PosDatasource().cachedShiftSnapshot(outletId, shiftId));
    final shiftSource = tillResult == null
        ? 'unknown'
        : tillResult.usedCache
        ? (ConnectivityService.instance.online.value
              ? 'cache_fallback'
              : 'cache_offline')
        : 'server';

    // Nomor struk lokal: server belum menomori saat kertas keluar, jadi ini
    // rujukan yang dipegang pelanggan. Diambil sebelum enqueue supaya nomor
    // yang tercetak = nomor yang tersimpan & tersinkron.
    final localReceiptNo = await LocalReceiptNumber.next();

    final payload = <String, dynamic>{
      'kind': 'paid',
      'clientOrderId': localOrderId,
      'localReceiptNo': localReceiptNo,
      'outletId': outletId,
      'createdBy': authState.profile.id,
      'orderType': posState.orderType.value,
      'tableId': posState.tableId,
      'customerName': posState.customerName,
      'subtotal': posState.subtotal,
      'discountAmount': posState.discountAmount,
      'taxAmount': posState.taxAmount,
      'serviceCharge': posState.serviceCharge,
      // Snapshot perlakuan pajak saat transaksi — order bisa tersinkron
      // berhari-hari kemudian, setelah setelan outlet berubah.
      'taxInclusive': posState.taxInclusiveForOrder,
      'rounding': posState.rounding,
      'total': posState.total,
      'paymentMethod': _method.value,
      'amount': posState.total,
      'idempotencyKey': uuid.v4(),
      if (paymentBreakdown.isNotEmpty)
        'payments': paymentBreakdown.entries
            .map(
              (entry) => {
                'method': entry.key.value,
                'amount': entry.value,
                'idempotencyKey': uuid.v4(),
              },
            )
            .toList(),
      // Till & loyalty & promo ikut dititipkan ke antrean — jalur ini sekarang
      // dipakai SEMUA transaksi, jadi replay harus setara createOrder +
      // _afterOrderSettled. Tanpa ini kas tunai tak masuk laci dan poin hangus.
      'shiftId': shiftId,
      // Snapshot diagnosis. Server tetap menjadi sumber kebenaran; metadata ini
      // dipakai bila transaksi ditolak agar ID cache lama dapat dilacak tanpa
      // membuka penyimpanan Hive secara manual.
      'shiftStartedAt': shiftSnapshot?['start_time'],
      'shiftVerifiedAt': shiftSnapshot?['verified_at'],
      'shiftCashierId': shiftSnapshot?['kasir_id'],
      'shiftSource': shiftSource,
      'loyaltyMemberId': posState.loyaltyMemberId,
      'loyaltyDiscount': posState.loyaltyDiscount,
      'redeemedPoints': posState.redeemedPoints,
      'promoId': posState.promoId,
      'voucherId': posState.voucherId,
      // Draf lama dipertahankan sampai order pengganti berhasil tersinkron.
      'replacesOrderId': posState.editingOrderId,
      'clockSource': ConnectivityService.instance.hasTrustedServerClock
          ? 'server_offset'
          : 'device',
      // Instan UTC — nilai ini dikirim ke kolom timestamptz saat replay sync.
      'createdAt': ConnectivityService.instance
          .trustedUtcNow()
          .toIso8601String(),
      'items': posState.cart
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

    // Enqueue DULU, cetak belakangan: kalau urutannya dibalik dan aplikasi mati
    // tepat setelah struk keluar, pelanggan pegang struk untuk transaksi yang
    // tak pernah tercatat di mana pun. Hive.add() menulis ke disk lokal
    // (~milidetik), jadi ini tidak menggerus target 0.1 detik.
    try {
      await OfflineQueueService.instance.enqueue(payload);
      final ordersDatasource = OrdersDatasource();
      await ordersDatasource.cacheQueuedOrder(payload);
      await ordersDatasource.setCachedTableStatus(
        outletId: outletId,
        tableId: posState.tableId,
        status: 'available',
      );
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _processing = false);
      AppToast.error(
        context,
        humanizeError(e, fallback: 'Gagal menyimpan transaksi.'),
      );
      return;
    }

    // Cetak dari data di layar. Dilakukan sebelum keranjang dikosongkan karena
    // struk dibangun dari posState.cart.
    if (context.mounted) {
      await _printReceiptNow(
        context: context,
        clientOrderId: localOrderId,
        localReceiptNo: localReceiptNo,
        outletId: outletId,
        posState: posState,
        method: paymentBreakdown.isEmpty
            ? _method
            : paymentBreakdown.keys.first,
        cashReceived: paymentBreakdown.isEmpty && _method == PaymentMethod.cash
            ? _cashReceived
            : null,
        paymentBreakdown: paymentBreakdown,
        cashierName: authState.profile.fullName,
      );
    }

    // Sinkron di latar belakang — sengaja TIDAK di-await: struk sudah keluar &
    // transaksi sudah aman di disk. Kalau offline, ini no-op dan SyncService
    // yang akan menuntaskannya sendiri begitu koneksi kembali.
    unawaited(SyncService.instance.sync());

    if (!context.mounted) return;
    context.read<PosBloc>().add(PosCartCleared());

    final kembalian = paymentBreakdown.isEmpty && _method == PaymentMethod.cash
        ? _cashReceived - posState.total
        : 0.0;
    await showPaymentSuccess(
      context,
      orderNumber: localReceiptNo,
      customerName: posState.customerName,
      orderType: posState.orderType,
      subtotal: posState.subtotal,
      tax: posState.taxAmount,
      service: posState.serviceCharge,
      total: posState.total,
      kembalian: kembalian,
      offline: !ConnectivityService.instance.online.value,
    );
    if (context.mounted) context.go('/kasir');
  }

  Future<void> _removeReplacedDraft(String? orderId) async {
    if (orderId == null || orderId.isEmpty) return;
    try {
      await OrdersDatasource().deleteOrder(orderId);
    } catch (_) {
      // Jangan menggagalkan transaksi baru hanya karena cleanup draf lama.
    }
  }
}

// ── Auto-print struk helper ──────────────────────────────────────────────────
// Jika printer belum terhubung, tampilkan popup agar user bisa connect dulu.
// Jika user memilih "Lewati", cetak struk dilewati (transaksi tetap berhasil).

/// Menjalankan cetak struk dan tiket dapur secara terpisah. Kegagalan atau
/// keputusan melewati struk tidak boleh menghentikan tiket dapur.
@visibleForTesting
Future<void> runIndependentPrintJobs({
  required Future<void> Function() receiptJob,
  required Future<void> Function() kitchenJob,
  void Function(Object error)? onReceiptError,
  void Function(Object error)? onKitchenError,
}) async {
  try {
    // Dapur diprioritaskan agar dialog/koneksi printer struk yang lambat tidak
    // menahan tiket produksi makanan dan minuman.
    await kitchenJob();
  } catch (error) {
    onKitchenError?.call(error);
  }
  try {
    await receiptJob();
  } catch (error) {
    onReceiptError?.call(error);
  }
}

Future<void> _tryPrintWalkinReceipt({
  required BuildContext context,
  required String orderId,
  required String outletId,
  required PosState cart,
  required PaymentMethod method,
  double? cashReceived,
  Map<PaymentMethod, double> paymentBreakdown = const {},
  String? cashierName,
}) async {
  if (outletId.isEmpty) return;
  // Hanya di platform yang support Bluetooth printing.
  if (!PrinterService.isSupported) return;
  await runIndependentPrintJobs(
    receiptJob: () async {
      final printer = PrinterService();
      // Gerbang Bluetooth HANYA bila printer struknya memang Bluetooth. Printer
      // LAN mencetak lewat socket (isConnected selamanya false untuknya) — dulu
      // gerbang ini membuatnya tak pernah mencetak & memunculkan dialog scan BT.
      if (await printer.receiptNeedsBluetoothConnect() &&
          !printer.isConnected) {
        // Coba auto-reconnect ke printer terakhir (diam, tanpa popup).
        final autoOk = await printer.tryAutoReconnect();
        if (!autoOk) {
          // Auto-reconnect gagal → tampilkan popup connect.
          if (!context.mounted) return;
          final connected = await showPrinterConnectDialog(context);
          if (!connected) return; // user pilih "Lewati"
        }
      }

      // Refetch order dengan items dari DB supaya struk akurat (qty, harga final)
      final orderData = await Supabase.instance.client
          .from('orders')
          .select(
            '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price))',
          )
          .eq('id', orderId)
          .single();
      final order = Order.fromJson(orderData);

      // Lewat datasource ber-cache → sekaligus menghangatkan cache outlet
      // sehingga struk tetap bisa dicetak saat offline nanti.
      final datasource = PosDatasource();
      final outletData =
          datasource.cachedOutletReceiptMap(outletId) ??
          await datasource.fetchOutletReceiptMap(outletId);
      if (outletData == null) return;

      final info = OutletReceiptInfo.fromMap(outletData);
      // Batas cetak: bila aktif & struk order ini sudah pernah dicetak → lewati.
      if (info.receipt.limitPrint &&
          await printer.receiptAlreadyPrinted(orderId)) {
        return;
      }
      final rcptPrinter = await printer.printerForReceipt();
      final paper = rcptPrinter?.paper == '80'
          ? PaperSize.mm80
          : PaperSize.mm58;
      final builder = ReceiptBuilder(
        outlet: info,
        paperSize: paper,
        driver: rcptPrinter?.driver ?? 'generic1',
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
      final outcome = await printer.printReceiptBytes(bytes, auto: true);
      // Hanya tandai "sudah dicetak" bila benar-benar KELUAR — struk yang gagal
      // ATAU yang dilewati (autoprint mati) harus tetap bisa dicetak ulang, tidak
      // boleh diblokir batas cetak.
      if (outcome.isPrinted && info.receipt.limitPrint) {
        await printer.markReceiptPrinted(orderId);
      }
      if (outcome.isFailed && context.mounted) {
        AppToast.error(
          context,
          'Struk gagal dicetak. Buka order → cetak ulang.',
        );
      }
    },
    kitchenJob: () => printKitchenTicketsForOrder(
      orderId: orderId,
      outletId: outletId,
      trigger: KitchenTrigger.bayar,
      printedBy: cashierName,
      skipIfAlreadyPrinted: true,
      claimBeforePrint: true,
    ),
    onReceiptError: (_) {
      if (context.mounted) {
        AppToast.error(
          context,
          'Struk gagal dicetak. Buka order → cetak ulang.',
        );
      }
    },
    onKitchenError: (_) {
      if (context.mounted) {
        AppToast.error(
          context,
          'Tiket dapur gagal dicetak. Buka order → Cetak Tiket Dapur.',
        );
      }
    },
  );
}

// Cetak struk SEKARANG, tanpa jaringan: bangun Order dari keranjang di layar +
// info outlet dari cache, lalu tembak ke printer. Semua pembacaan di sini wajib
// cache-only — satu await ke Supabase saja dan struk tak lagi keluar 0.1 detik.
Future<void> _printReceiptNow({
  required BuildContext context,
  required String clientOrderId,
  required String localReceiptNo,
  required String outletId,
  required PosState posState,
  required PaymentMethod method,
  double? cashReceived,
  Map<PaymentMethod, double> paymentBreakdown = const {},
  String? cashierName,
}) async {
  if (outletId.isEmpty) return;
  if (!PrinterService.isSupported) return;
  final ds = PosDatasource();
  final order = _buildLocalOrder(
    clientOrderId: clientOrderId,
    localReceiptNo: localReceiptNo,
    outletId: outletId,
    posState: posState,
  );
  KitchenPrintResult? kitchenResult;
  await runIndependentPrintJobs(
    receiptJob: () async {
      final printer = PrinterService();
      // Lihat catatan di _tryPrintWalkinReceipt: printer LAN tak punya konsep
      // "terhubung", jadi jangan gerbangi cetaknya dengan koneksi Bluetooth.
      if (await printer.receiptNeedsBluetoothConnect() &&
          !printer.isConnected) {
        final autoOk = await printer.tryAutoReconnect();
        if (!autoOk) {
          if (!context.mounted) return;
          final connected = await showPrinterConnectDialog(context);
          if (!connected) return; // user pilih "Lewati"
        }
      }

      // Info outlet dari cache (dihangatkan saat halaman bayar dibuka). Tanpa ini
      // struk tak bisa dibangun — beri tahu kasir agar cetak ulang nanti.
      final outletData = ds.cachedOutletReceiptMap(outletId);
      if (outletData == null) {
        if (context.mounted) {
          AppToast.error(
            context,
            'Data struk belum tersimpan. Cetak ulang dari Daftar Order.',
          );
        }
        return;
      }

      final info = OutletReceiptInfo.fromMap(outletData);

      if (info.receipt.limitPrint &&
          await printer.receiptAlreadyPrinted(clientOrderId)) {
        return;
      }
      final rcptPrinter = await printer.printerForReceipt();
      final paper = rcptPrinter?.paper == '80'
          ? PaperSize.mm80
          : PaperSize.mm58;
      final builder = ReceiptBuilder(
        outlet: info,
        paperSize: paper,
        driver: rcptPrinter?.driver ?? 'generic1',
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
      final outcome = await printer.printReceiptBytes(bytes, auto: true);
      if (outcome.isPrinted && info.receipt.limitPrint) {
        await printer.markReceiptPrinted(clientOrderId);
      }
      if (outcome.isFailed && context.mounted) {
        AppToast.error(
          context,
          'Struk gagal dicetak. Buka order → cetak ulang.',
        );
      }
    },
    kitchenJob: () async {
      kitchenResult = await printKitchenTicketsForLocalOrder(
        order: order,
        categoryNames: ds.cachedCategoryNames(outletId),
        trigger: KitchenTrigger.bayar,
        printedBy: cashierName,
      );
    },
    onReceiptError: (_) {
      if (context.mounted) {
        AppToast.error(
          context,
          'Struk gagal dicetak. Buka order → cetak ulang.',
        );
      }
    },
    onKitchenError: (_) {
      if (context.mounted) {
        AppToast.error(
          context,
          'Tiket dapur gagal dicetak. Buka order → Cetak Tiket Dapur.',
        );
      }
    },
  );
  if (kitchenResult?.hasPrinted == true || kitchenResult?.hasQueued == true) {
    final deviceId = await PrinterService().devicePrintId();
    await OfflineQueueService.instance.updateByClientOrderId(clientOrderId, {
      'localKitchenPrinted': true,
      'kitchenPrintDeviceId': deviceId,
    });
  }
}

/// Susun objek [Order] dari keranjang POS lokal untuk kebutuhan cetak.
Order _buildLocalOrder({
  required String clientOrderId,
  required String localReceiptNo,
  required String outletId,
  required PosState posState,
}) {
  const uuid = Uuid();
  final now = DateTime.now();
  final items = posState.cart
      .map(
        (item) => OrderItem(
          id: uuid.v4(),
          orderId: clientOrderId,
          menuItemId: item.menuItem.id,
          quantity: item.quantity,
          unitPrice: item.unitPrice,
          subtotal: item.subtotal,
          notes: item.notes,
          menuItem: item.menuItem,
          options: item.selectedExtras
              .map(
                (e) => OrderItemOption(
                  extraName: e.extraName,
                  optionName: e.optionName,
                  price: e.price,
                ),
              )
              .toList(),
        ),
      )
      .toList();
  return Order(
    id: clientOrderId,
    outletId: outletId,
    // Objek ini hanya untuk dicetak — server belum menomori, jadi baris
    // "No Nota" di struk diisi nomor lokal perangkat. Order yang tersimpan di
    // server tetap mendapat order_number aslinya saat sync.
    orderNumber: localReceiptNo,
    orderType: posState.orderType,
    tableId: posState.tableId,
    tableNumber: posState.tableNumber,
    status: OrderStatus.paid,
    customerName: posState.customerName,
    subtotal: posState.subtotal,
    discountAmount: posState.discountAmount,
    taxAmount: posState.taxAmount,
    serviceCharge: posState.serviceCharge,
    totalAmount: posState.total,
    stockDeducted: false,
    createdAt: now,
    updatedAt: now,
    items: items,
  );
}

// ── Numpad ────────────────────────────────────────────────────────────────────

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
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.6,
      physics: const NeverScrollableScrollPhysics(),
      children: _keys
          .map((k) => _NumpadKey(label: k, onTap: () => onKey(k)))
          .toList(),
    );
  }
}

class _NumpadKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NumpadKey({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDelete = label == '⌫';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isDelete
              ? AppColors.error.withValues(alpha: 0.08)
              : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDelete
                ? AppColors.error.withValues(alpha: 0.3)
                : AppColors.border,
          ),
        ),
        child: Center(
          child: isDelete
              ? const Icon(
                  Icons.backspace_outlined,
                  color: AppColors.error,
                  size: 20,
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
        ),
      ),
    );
  }
}

// ── Nominal cepat ─────────────────────────────────────────────────────────────

class _QuickCashRow extends StatelessWidget {
  final double total;
  final ValueChanged<double> onSelect;
  const _QuickCashRow({required this.total, required this.onSelect});

  static List<double> _quickAmounts(double total) {
    final rounds = {
      _roundUp(total, 5000),
      _roundUp(total, 10000),
      _roundUp(total, 20000),
      _roundUp(total, 50000),
      _roundUp(total, 100000),
    }.toList()..sort();
    return rounds.take(4).toList();
  }

  static double _roundUp(double v, double to) => (v / to).ceil() * to;

  @override
  Widget build(BuildContext context) {
    final amounts = _quickAmounts(total);
    return Row(
      children: amounts
          .map(
            (a) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: OutlinedButton(
                  onPressed: () => onSelect(a),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    side: const BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    CurrencyFormatter.format(a),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textPrimary,
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

// ── Method card ───────────────────────────────────────────────────────────────

class _MethodCard extends StatelessWidget {
  final PaymentMethod method;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MethodCard({
    required this.method,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : Colors.white,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: selected ? AppColors.primary : AppColors.textSecondary,
              size: 22,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.primary : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bagi tagihan saat checkout (order baru sudah dibuat) ─────────────────────
class _SplitSheet extends StatefulWidget {
  final String orderId;
  final String outletId;
  final String shiftId;
  final String expectedUserId;
  final double total;
  final Set<String> enabledMethods;
  final bool offline;
  final Future<void> Function(Map<PaymentMethod, double> paymentBreakdown)
  onFinalized;
  const _SplitSheet({
    required this.orderId,
    required this.outletId,
    required this.shiftId,
    required this.expectedUserId,
    required this.total,
    required this.enabledMethods,
    this.offline = false,
    required this.onFinalized,
  });

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
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
  bool _busy = false;
  String? _retryOperationId;
  String? _retrySignature;
  String? _retryIdempotencyKey;

  double get _paid => _splits.fold<double>(0, (s, e) => s + e.amount);
  double get _remaining => (widget.total - _paid).clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    _amountCtrl.text = formatThousands(_remaining);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final amt = parseThousands(_amountCtrl.text);
    if (amt <= 0) {
      AppToast.error(context, 'Nominal harus lebih dari 0');
      return;
    }
    final capped = amt > _remaining ? _remaining : amt;
    final completesPayment = capped >= _remaining - 0.01;
    if (widget.offline) {
      setState(() {
        _splits.add((method: _method, amount: capped));
        _amountCtrl.text = _remaining > 0 ? formatThousands(_remaining) : '';
      });
      if (completesPayment && mounted) {
        await _finalize();
      }
      return;
    }
    final signature =
        '${widget.orderId}|${_method.value}|$capped|${widget.shiftId}';
    final journal = TransactionJournalService.instance;
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
    if (existingJournal == null) {
      await journal.enqueue(
        id: operationId,
        type: 'split_payment',
        payload: {
          'orderId': widget.orderId,
          'outletId': widget.outletId,
          'shiftId': widget.shiftId,
          'method': _method.value,
          'amount': capped,
          'finalize': completesPayment,
          'idempotencyKey': idempotencyKey,
          'expectedUserId': widget.expectedUserId,
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
    try {
      await _ds.addSplitPayment(
        orderId: widget.orderId,
        outletId: widget.outletId,
        shiftId: widget.shiftId,
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
        await journal.markPending(operationId, e);
        _retryOperationId = operationId;
        _retrySignature = signature;
        _retryIdempotencyKey = idempotencyKey;
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

  Future<void> _finalize() async {
    setState(() => _busy = true);
    final paymentBreakdown = <PaymentMethod, double>{};
    for (final split in _splits) {
      paymentBreakdown.update(
        split.method,
        (amount) => amount + split.amount,
        ifAbsent: () => split.amount,
      );
    }
    if (widget.offline) {
      try {
        await widget.onFinalized(Map.unmodifiable(paymentBreakdown));
        if (mounted) Navigator.pop(context, true);
      } catch (error) {
        if (!mounted) return;
        setState(() => _busy = false);
        AppToast.error(
          context,
          humanizeError(error, fallback: 'Gagal menyimpan pembayaran.'),
        );
      }
      return;
    }
    final journal = TransactionJournalService.instance;
    final operationId = 'split-finalize-${widget.orderId}';
    if (journal.get(operationId) == null) {
      await journal.enqueue(
        id: operationId,
        type: 'split_finalize',
        payload: {
          'orderId': widget.orderId,
          'expectedUserId': widget.expectedUserId,
        },
      );
    }
    await journal.markSending(operationId);
    try {
      await widget.onFinalized(Map.unmodifiable(paymentBreakdown));
      await journal.remove(operationId);
      if (mounted) Navigator.pop(context, true);
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
        .where((m) => widget.enabledMethods.contains(m.$1.value))
        .toList();
    return PopScope(
      canPop: !_busy,
      child: Padding(
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
                const Text(
                  'Bagi Tagihan',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 16),
                _row('Total Tagihan', widget.total, bold: true),
                const SizedBox(height: 4),
                _row('Terbayar', _paid, color: AppColors.success),
                const SizedBox(height: 4),
                _row(
                  'Sisa',
                  _remaining,
                  big: true,
                  color: _remaining > 0 ? AppColors.error : AppColors.success,
                ),
                const Divider(height: 24),
                for (final e in _splits)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 16,
                          color: AppColors.success,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _label(e.method),
                          style: const TextStyle(fontSize: 13),
                        ),
                        const Spacer(),
                        Text(
                          CurrencyFormatter.format(e.amount),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!done) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Tambah Pembayaran',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
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
                          // Format ribuan saat mengetik: 10000 → 10.000.
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
                        onPressed: _busy ? null : _add,
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
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('Tutup Bagi Tagihan'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
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

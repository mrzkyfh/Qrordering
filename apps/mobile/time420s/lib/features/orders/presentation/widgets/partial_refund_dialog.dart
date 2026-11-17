import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/services/supabase_service.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../data/datasources/orders_datasource.dart';

typedef RefundItemsLoader =
    Future<List<Map<String, dynamic>>> Function(String orderId);
typedef RefundApproversLoader =
    Future<List<Map<String, dynamic>>> Function(String outletId);

/// Modal refund SEBAGIAN (pilih item + qty). Order tetap 'paid', stok tak
/// dikembalikan, wajib PIN approver. Mengembalikan true bila berhasil.
Future<bool> showPartialRefundDialog(
  BuildContext context, {
  required Order order,
}) async {
  final res = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _PartialRefundSheet(order: order),
  );
  return res == true;
}

/// Permukaan uji widget tanpa jaringan. Jalur produksi tetap memakai
/// [showPartialRefundDialog] dan datasource Supabase.
@visibleForTesting
Widget partialRefundSheetForTesting({
  required Order order,
  required RefundItemsLoader loadItems,
  required RefundApproversLoader loadApprovers,
}) => _PartialRefundSheet(
  order: order,
  loadItems: loadItems,
  loadApprovers: loadApprovers,
);

class _PartialRefundSheet extends StatefulWidget {
  final Order order;
  final RefundItemsLoader? loadItems;
  final RefundApproversLoader? loadApprovers;

  const _PartialRefundSheet({
    required this.order,
    this.loadItems,
    this.loadApprovers,
  });
  @override
  State<_PartialRefundSheet> createState() => _PartialRefundSheetState();
}

class _PartialRefundSheetState extends State<_PartialRefundSheet> {
  final _ds = OrdersDatasource();
  final _svc = SupabaseService();
  final _pinCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();

  List<Map<String, dynamic>> _items = const [];
  List<Map<String, dynamic>> _approvers = const [];
  final Map<String, int> _qty = {}; // order_item_id -> qty refund
  String? _approverId;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;

  bool _canApprove(Map<String, dynamic> approver) =>
      approver['can_refund'] == true;

  bool get _hasEligibleApprover => _approvers.any(_canApprove);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final items = widget.loadItems != null
          ? await widget.loadItems!(widget.order.id)
          : await _ds.fetchRefundableItems(widget.order.id);
      final staff = widget.loadApprovers != null
          ? await widget.loadApprovers!(widget.order.outletId)
          : await _svc.listClockinStaff(widget.order.outletId);
      final approvers = staff.where((s) {
        final role = (s['role'] ?? '') as String;
        return s['has_pin'] == true &&
            (role == 'owner' || role == 'admin' || role == 'manajer');
      }).toList();
      if (mounted) {
        setState(() {
          _items = items;
          _approvers = approvers;
          if (!_approvers.any(
            (approver) =>
                approver['id'] == _approverId && _canApprove(approver),
          )) {
            _approverId = null;
          }
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = humanizeError(
            error,
            fallback:
                'Data refund belum dapat dimuat. Periksa koneksi lalu coba lagi.',
          );
        });
      }
    }
  }

  double get _total {
    double t = 0;
    for (final it in _items) {
      final q = _qty[it['id'] as String] ?? 0;
      t += (it['unit_price'] as double) * q;
    }
    return t;
  }

  bool get _canConfirm =>
      _total > 0 && _approverId != null && _pinCtrl.text.trim().length == 4;

  Future<void> _submit() async {
    if (!_canConfirm || _busy) return;
    setState(() => _busy = true);
    try {
      final items = _qty.entries
          .where((e) => e.value > 0)
          .map((e) => {'order_item_id': e.key, 'qty': e.value})
          .toList();
      if (!ConnectivityService.instance.online.value) {
        final operationId =
            'manual-review-refund-items-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        await journal.enqueue(
          id: operationId,
          type: 'manual_review',
          payload: {
            'operation': 'refund_order_items',
            'orderId': widget.order.id,
            'items': items,
            'total': _total,
            'reason': _reasonCtrl.text.trim(),
            'approverId': _approverId,
            'requiresPinWhenOnline': true,
          },
        );
        await journal.markNeedsReview(
          operationId,
          'Menunggu verifikasi PIN saat online',
        );
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context, false);
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Permintaan refund disimpan. Hubungkan internet lalu buka order dan verifikasi PIN kembali.',
            ),
          ),
        );
        return;
      }
      await _ds.refundOrderItems(
        widget.order.id,
        items: items,
        reason: _reasonCtrl.text.trim().isEmpty
            ? null
            : _reasonCtrl.text.trim(),
        approverPin: _pinCtrl.text.trim(),
        approverId: _approverId,
      );
      await TransactionJournalService.instance.resolveManualReviews(
        operation: 'refund_order_items',
        orderId: widget.order.id,
        items: items,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      AppToast.success(context, 'Refund sebagian berhasil');
    } catch (e) {
      if (isBackendTransportFailure(e)) {
        final operationId =
            'manual-review-refund-items-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        await journal.enqueue(
          id: operationId,
          type: 'manual_review',
          payload: {
            'operation': 'refund_order_items',
            'orderId': widget.order.id,
            'items': _qty.entries
                .where((entry) => entry.value > 0)
                .map(
                  (entry) => {'order_item_id': entry.key, 'qty': entry.value},
                )
                .toList(),
            'total': _total,
            'reason': _reasonCtrl.text.trim(),
            'approverId': _approverId,
            'requiresPinWhenOnline': true,
            // PIN tidak pernah disimpan di perangkat.
          },
        );
        await journal.markNeedsReview(operationId, e);
      }
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(context, humanizeError(e, fallback: 'Gagal refund.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: _loading
          ? const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            )
          : _loadError != null
          ? _loadFailure()
          : Column(
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
                const SizedBox(height: 14),
                const Text(
                  'Refund Sebagian',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  'Order #${widget.order.orderNumber}',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'Tidak ada item yang masih dapat direfund.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          )
                        else
                          ..._items.map(_itemRow),
                        const SizedBox(height: 12),
                        _approverDropdown(),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pinCtrl,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 4,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'PIN Approver (4 digit)',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _reasonCtrl,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Alasan (opsional)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Total refund',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const Spacer(),
                    Text(
                      CurrencyFormatter.format(_total),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                    ),
                    onPressed: (_canConfirm && !_busy) ? _submit : null,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Konfirmasi Refund'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _loadFailure() {
    return SizedBox(
      height: 220,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: AppColors.error,
              size: 32,
            ),
            const SizedBox(height: 10),
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba Lagi'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final id = it['id'] as String;
    final qtySold = it['quantity'] as int;
    final refunded = it['refunded_qty'] as int;
    final remaining = qtySold - refunded;
    final sel = _qty[id] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it['name'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Sisa bisa refund: $remaining · ${CurrencyFormatter.format(it['unit_price'] as double)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: sel > 0
                ? () => setState(() => _qty[id] = sel - 1)
                : null,
          ),
          Text('$sel', style: const TextStyle(fontWeight: FontWeight.w600)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: sel < remaining
                ? () => setState(() => _qty[id] = sel + 1)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _approverDropdown() {
    if (_approvers.isEmpty) {
      return const Text(
        'Tidak ada atasan ber-PIN untuk menyetujui.',
        style: TextStyle(color: AppColors.error, fontSize: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _approverId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Disetujui oleh',
            border: OutlineInputBorder(),
          ),
          items: _approvers.map((a) {
            final canApprove = _canApprove(a);
            return DropdownMenuItem<String>(
              value: a['id'] as String,
              enabled: canApprove,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      canApprove
                          ? '${a['full_name'] ?? a['name'] ?? 'Staff'} (${a['role']})'
                          : '${a['full_name'] ?? a['name'] ?? 'Staff'} — Tidak memiliki akses refund',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: canApprove ? null : AppColors.textDisabled,
                      ),
                    ),
                  ),
                  if (!canApprove)
                    const Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: AppColors.textDisabled,
                    ),
                ],
              ),
            );
          }).toList(),
          // Tetap dapat dibuka saat semua approver terkunci agar alasan dan
          // status mereka terlihat; item yang tidak eligible tetap disabled.
          onChanged: (v) {
            if (v != null) setState(() => _approverId = v);
          },
        ),
        if (!_hasEligibleApprover)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Tidak ada staf yang memiliki akses refund.',
              style: TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

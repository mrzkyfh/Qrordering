import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/void_receipt_print.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/supabase_service.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/datasources/orders_datasource.dart';

typedef VoidItemsLoader =
    Future<List<Map<String, dynamic>>> Function(String orderId);
typedef VoidApproversLoader =
    Future<List<Map<String, dynamic>>> Function(String outletId);

/// Pilih item dan jumlah yang dibatalkan dari order belum lunas.
Future<bool> showItemVoidDialog(
  BuildContext context, {
  required Order order,
  ValueChanged<Map<String, dynamic>>? onVoided,
}) async {
  final screenHeight = MediaQuery.sizeOf(context).height;
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: 720, maxHeight: screenHeight * 0.9),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _ItemVoidSheet(order: order, onVoided: onVoided),
  );
  return result == true;
}

@visibleForTesting
Widget itemVoidSheetForTesting({
  required Order order,
  required VoidItemsLoader loadItems,
  required VoidApproversLoader loadApprovers,
}) => _ItemVoidSheet(
  order: order,
  loadItems: loadItems,
  loadApprovers: loadApprovers,
);

class _ItemVoidSheet extends StatefulWidget {
  final Order order;
  final VoidItemsLoader? loadItems;
  final VoidApproversLoader? loadApprovers;
  final ValueChanged<Map<String, dynamic>>? onVoided;

  const _ItemVoidSheet({
    required this.order,
    this.loadItems,
    this.loadApprovers,
    this.onVoided,
  });

  @override
  State<_ItemVoidSheet> createState() => _ItemVoidSheetState();
}

class _ItemVoidSheetState extends State<_ItemVoidSheet> {
  final _datasource = OrdersDatasource();
  final _service = SupabaseService();
  final _pinController = TextEditingController();
  final _reasonController = TextEditingController();
  final Map<String, int> _selectedQty = {};

  List<Map<String, dynamic>> _items = const [];
  List<Map<String, dynamic>> _approvers = const [];
  String? _approverId;
  bool _loading = true;
  bool _submitting = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        widget.loadItems != null
            ? widget.loadItems!(widget.order.id)
            : _datasource.fetchVoidableItems(widget.order.id),
        widget.loadApprovers != null
            ? widget.loadApprovers!(widget.order.outletId)
            : _service.listClockinStaff(widget.order.outletId),
      ]);
      final staff = results[1];
      final approvers = staff.where((entry) {
        final role = entry['role'] as String? ?? '';
        return entry['has_pin'] == true &&
            (role == 'owner' || role == 'admin' || role == 'manajer');
      }).toList();
      if (!mounted) return;
      setState(() {
        _items = results[0];
        _approvers = approvers;
        _loading = false;
      });
    } catch (error) {
      if (isBackendTransportFailure(error)) {
        final operationId =
            'manual-review-void-items-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        await journal.enqueue(
          id: operationId,
          type: 'manual_review',
          payload: {
            'operation': 'void_order_items',
            'orderId': widget.order.id,
            'quantity': _quantity,
            'reason': _reasonController.text.trim(),
            // PIN tidak pernah disimpan di perangkat.
          },
        );
        await journal.markNeedsReview(operationId, error);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = humanizeError(
          error,
          fallback:
              'Daftar item belum dapat dimuat. Periksa koneksi lalu coba lagi.',
        );
      });
    }
  }

  double get _total {
    var value = 0.0;
    for (final item in _items) {
      value +=
          (_selectedQty[item['id'] as String] ?? 0) *
          (item['unit_price'] as double);
    }
    return value;
  }

  int get _quantity =>
      _selectedQty.values.fold(0, (sum, quantity) => sum + quantity);

  void _selectAll() {
    setState(() {
      _selectedQty
        ..clear()
        ..addEntries(
          _items.map(
            (item) => MapEntry(item['id'] as String, item['quantity'] as int),
          ),
        );
    });
  }

  bool get _canSubmit =>
      _quantity > 0 &&
      _approverId != null &&
      _pinController.text.trim().length == 4 &&
      _reasonController.text.trim().isNotEmpty;

  List<OrderItem> _selectedOrderItems() {
    final originals = widget.order.items ?? const <OrderItem>[];
    return originals.where((item) => (_selectedQty[item.id] ?? 0) > 0).map((
      item,
    ) {
      final quantity = _selectedQty[item.id]!;
      return OrderItem(
        id: item.id,
        orderId: item.orderId,
        menuItemId: item.menuItemId,
        quantity: quantity,
        unitPrice: item.unitPrice,
        subtotal: item.unitPrice * quantity,
        notes: item.notes,
        menuItem: item.menuItem,
        options: item.options,
      );
    }).toList();
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    final selectedItems = _selectedOrderItems();
    setState(() => _submitting = true);
    try {
      final payload = _selectedQty.entries
          .where((entry) => entry.value > 0)
          .map((entry) => {'order_item_id': entry.key, 'qty': entry.value})
          .toList();
      if (!ConnectivityService.instance.online.value) {
        final operationId =
            'manual-review-void-items-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        await journal.enqueue(
          id: operationId,
          type: 'manual_review',
          payload: {
            'operation': 'void_order_items',
            'orderId': widget.order.id,
            'items': payload,
            'reason': _reasonController.text.trim(),
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
              'Permintaan void disimpan. Hubungkan internet lalu buka order dan verifikasi PIN kembali.',
            ),
          ),
        );
        return;
      }
      final result = await _datasource.voidOrderItems(
        widget.order.id,
        items: payload,
        reason: _reasonController.text.trim(),
        approverPin: _pinController.text.trim(),
        approverId: _approverId!,
      );
      await TransactionJournalService.instance.resolveManualReviews(
        operation: 'void_order_items',
        orderId: widget.order.id,
        items: payload,
      );

      PrintOutcome? printResult;
      if (selectedItems.isNotEmpty) {
        if (!mounted) return;
        final auth = context.read<AuthBloc>().state;
        final printedBy = auth is AuthAuthenticated
            ? auth.profile.fullName
            : result['approver'] as String?;
        try {
          printResult = await printVoidReceipt(
            order: widget.order,
            items: selectedItems,
            reason: _reasonController.text.trim(),
            approverName: printedBy,
          );
        } catch (_) {
          // Void telah sah di server. Gangguan printer tidak boleh mengubahnya
          // menjadi pesan "void gagal".
        }
      }

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      widget.onVoided?.call(result);
      Navigator.pop(context, true);
      final suffix = switch (printResult) {
        PrintOutcome.printed => ' Struk void dicetak di Kasir Utama.',
        PrintOutcome.failed => ' Struk void Kasir Utama masuk antrean cetak.',
        PrintOutcome.skipped => ' Printer Kasir Utama belum dikonfigurasi.',
        null => '',
      };
      messenger.showSnackBar(
        SnackBar(content: Text('$_quantity item berhasil di-void.$suffix')),
      );
    } catch (error) {
      // RPC void item tidak boleh diulang otomatis: bila respons hilang
      // setelah server berkomit, pengulangan dapat menggandakan void parsial.
      // Simpan sebagai transaksi yang perlu dikonfirmasi di server, sama
      // seperti void/refund penuh, agar kasir tidak menekan ulang secara buta.
      if (isBackendTransportFailure(error)) {
        final operationId =
            'manual-review-void-items-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        try {
          await journal.enqueue(
            id: operationId,
            type: 'manual_review',
            payload: {
              'operation': 'void_order_items',
              'orderId': widget.order.id,
              'items': _selectedQty.entries
                  .where((entry) => entry.value > 0)
                  .map(
                    (entry) => {'order_item_id': entry.key, 'qty': entry.value},
                  )
                  .toList(),
              'reason': _reasonController.text.trim(),
              'approverId': _approverId,
              'requiresPinWhenOnline': true,
              // PIN tidak pernah disimpan di perangkat.
            },
          );
          await journal.markNeedsReview(operationId, error);
        } catch (_) {
          // Kegagalan jurnal lokal tidak boleh menutupi error jaringan asli.
        }
      }
      if (!mounted) return;
      setState(() => _submitting = false);
      final transportFailure = isBackendTransportFailure(error);
      AppToast.error(
        context,
        transportFailure
            ? 'Status void belum dapat dipastikan. Periksa daftar order sebelum mencoba lagi.'
            : humanizeError(error, fallback: 'Void item gagal.'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      key: const Key('void-item-sheet'),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: _loading
            ? const SizedBox(
                height: 180,
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Void Item',
                              style: TextStyle(
                                fontSize: 21,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                                color: AppColors.slate900,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'Pilih menu dan jumlah yang batal dari Order #${widget.order.orderNumber}.',
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: 'Tutup',
                        onPressed: _submitting
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.slate100,
                          foregroundColor: AppColors.slate600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ITEM YANG DIBATALKAN',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 0.8,
                              fontWeight: FontWeight.w700,
                              color: AppColors.slate500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_items.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text(
                                  'Tidak ada item yang dapat di-void.',
                                ),
                              ),
                            )
                          else
                            ..._items.map(_itemRow),
                          const SizedBox(height: 18),
                          const Text(
                            'OTORISASI VOID',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 0.8,
                              fontWeight: FontWeight.w700,
                              color: AppColors.slate500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _approverDropdown(),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _pinController,
                            keyboardType: TextInputType.number,
                            obscureText: true,
                            maxLength: 4,
                            onChanged: (_) => setState(() {}),
                            decoration: _fieldDecoration(
                              labelText: 'PIN pemberi izin (4 angka)',
                              counterText: '',
                              prefixIcon: Icons.lock_outline_rounded,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _reasonController,
                            maxLines: 2,
                            onChanged: (_) => setState(() {}),
                            decoration: _fieldDecoration(
                              labelText: 'Alasan void',
                              hintText:
                                  'Contoh: pelanggan membatalkan satu menu',
                              prefixIcon: Icons.notes_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: AppColors.slate200),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        '$_quantity item dipilih',
                        style: const TextStyle(
                          color: AppColors.slate600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _submitting || _items.isEmpty
                            ? null
                            : _selectAll,
                        icon: const Icon(Icons.done_all_rounded, size: 18),
                        label: const Text('Pilih Semua'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.error,
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text(
                        'Total dibatalkan',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
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
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.error,
                      ),
                      onPressed: _canSubmit && !_submitting ? _submit : null,
                      icon: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.remove_shopping_cart_outlined),
                      label: Text(
                        _submitting ? 'Memproses...' : 'Konfirmasi Void Item',
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _loadFailure() => SizedBox(
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

  Widget _itemRow(Map<String, dynamic> item) {
    final id = item['id'] as String;
    final maximum = item['quantity'] as int;
    final selected = _selectedQty[id] ?? 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: selected > 0 ? AppColors.primarySubtle : AppColors.slate50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected > 0 ? AppColors.primaryLight : AppColors.slate200,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['name'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Tersedia $maximum · ${CurrencyFormatter.format(item['unit_price'] as double)}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.slate200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Kurangi',
                  visualDensity: VisualDensity.compact,
                  onPressed: selected > 0
                      ? () => setState(() => _selectedQty[id] = selected - 1)
                      : null,
                  icon: const Icon(Icons.remove_rounded, size: 20),
                ),
                SizedBox(
                  width: 24,
                  child: Text(
                    '$selected',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.slate900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Tambah',
                  visualDensity: VisualDensity.compact,
                  onPressed: selected < maximum
                      ? () => setState(() => _selectedQty[id] = selected + 1)
                      : null,
                  icon: const Icon(Icons.add_rounded, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _approverDropdown() {
    if (_approvers.isEmpty) {
      return const Text(
        'Belum ada Owner, Admin, atau Manajer yang memiliki PIN.',
        style: TextStyle(color: AppColors.error, fontSize: 13),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _approverId,
      isExpanded: true,
      decoration: _fieldDecoration(
        labelText: 'Disetujui oleh',
        prefixIcon: Icons.verified_user_outlined,
      ),
      items: _approvers
          .map(
            (entry) => DropdownMenuItem<String>(
              value: entry['id'] as String,
              child: Text(
                '${entry['full_name'] ?? entry['name'] ?? 'Staff'} (${entry['role']})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (value) => setState(() => _approverId = value),
    );
  }

  InputDecoration _fieldDecoration({
    required String labelText,
    String? hintText,
    String? counterText,
    IconData? prefixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      counterText: counterText,
      prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 20),
      filled: true,
      fillColor: AppColors.slate50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.slate200),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }
}

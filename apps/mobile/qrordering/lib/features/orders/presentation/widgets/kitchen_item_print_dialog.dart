import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/printer_service.dart';

typedef KitchenItemsPrinter =
    Future<KitchenPrintResult> Function(
      List<OrderItem> items,
      String targetPrinterId,
    );

/// Menampilkan pemilih item untuk cetak ulang tiket dapur secara manual.
Future<KitchenPrintResult?> showKitchenItemPrintDialog(
  BuildContext context, {
  required Order order,
  String? printedBy,
  KitchenItemsPrinter? printItems,
  List<SavedPrinter>? initialPrinters,
}) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<KitchenPrintResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: 720, maxHeight: screenHeight * 0.88),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => _KitchenItemPrintSheet(
      order: order,
      printItems:
          printItems ??
          (items, targetPrinterId) => printKitchenTicketsForSelectedItems(
            order: order,
            items: items,
            targetPrinterId: targetPrinterId,
            printedBy: printedBy,
          ),
      initialPrinters: initialPrinters,
    ),
  );
}

@visibleForTesting
Widget kitchenItemPrintSheetForTesting({
  required Order order,
  required KitchenItemsPrinter printItems,
  List<SavedPrinter>? printers,
}) => _KitchenItemPrintSheet(
  order: order,
  printItems: printItems,
  initialPrinters: printers,
);

class _KitchenItemPrintSheet extends StatefulWidget {
  final Order order;
  final KitchenItemsPrinter printItems;
  final List<SavedPrinter>? initialPrinters;

  const _KitchenItemPrintSheet({
    required this.order,
    required this.printItems,
    this.initialPrinters,
  });

  @override
  State<_KitchenItemPrintSheet> createState() => _KitchenItemPrintSheetState();
}

class _KitchenItemPrintSheetState extends State<_KitchenItemPrintSheet> {
  final Map<String, int> _selectedQuantities = {};
  bool _printing = false;
  String? _error;
  List<SavedPrinter> _printers = const [];
  String? _targetPrinterId;
  bool _loadingPrinters = true;

  @override
  void initState() {
    super.initState();
    final supplied = widget.initialPrinters;
    if (supplied != null) {
      _setPrinters(supplied);
    } else {
      _loadPrinters();
    }
  }

  void _setPrinters(List<SavedPrinter> printers) {
    _printers = printers.where((printer) => printer.dapurEnabled).toList();
    _targetPrinterId = _printers.length == 1 ? _printers.single.id : null;
    _loadingPrinters = false;
  }

  Future<void> _loadPrinters() async {
    final printers = await PrinterService().kitchenPrinters();
    if (!mounted) return;
    setState(() => _setPrinters(printers));
  }

  List<OrderItem> get _items => (widget.order.items ?? const <OrderItem>[])
      .where((item) => item.quantity > 0)
      .toList();

  int get _selectedCount =>
      _selectedQuantities.values.fold(0, (total, quantity) => total + quantity);

  List<OrderItem> _selectedItems() {
    return _items.where((item) => (_selectedQuantities[item.id] ?? 0) > 0).map((
      item,
    ) {
      final quantity = _selectedQuantities[item.id]!;
      final subtotalPerItem = item.quantity > 0
          ? item.subtotal / item.quantity
          : item.unitPrice;
      return OrderItem(
        id: item.id,
        orderId: item.orderId,
        menuItemId: item.menuItemId,
        quantity: quantity,
        unitPrice: item.unitPrice,
        subtotal: subtotalPerItem * quantity,
        notes: item.notes,
        menuItem: item.menuItem,
        options: item.options,
      );
    }).toList();
  }

  Future<void> _print() async {
    if (_printing || _selectedCount == 0 || _targetPrinterId == null) return;
    setState(() {
      _printing = true;
      _error = null;
    });
    try {
      final result = await widget.printItems(
        _selectedItems(),
        _targetPrinterId!,
      );
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _printing = false;
        _error =
            'Tiket belum dapat dicetak. Periksa sambungan printer lalu coba lagi.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('kitchen-item-sheet'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 42,
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
                      'Cetak Tiket Dapur',
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: AppColors.slate900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Pilih menu dan jumlah yang ingin dicetak untuk Order #${widget.order.orderNumber}.',
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
                onPressed: _printing ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.slate100,
                  foregroundColor: AppColors.slate600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
            key: const Key('kitchen-target-printer'),
            initialValue: _targetPrinterId,
            decoration: const InputDecoration(
              labelText: 'Printer dapur tujuan',
              border: OutlineInputBorder(),
            ),
            hint: Text(
              _loadingPrinters
                  ? 'Memuat printer...'
                  : _printers.isEmpty
                  ? 'Belum ada printer dapur'
                  : 'Pilih satu printer',
            ),
            items: _printers
                .map(
                  (printer) => DropdownMenuItem(
                    value: printer.id,
                    child: Text(printer.name),
                  ),
                )
                .toList(),
            onChanged: _printing
                ? null
                : (value) => setState(() => _targetPrinterId = value),
          ),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            const SizedBox(
              height: 136,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 32,
                      color: AppColors.slate400,
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Pesanan ini tidak memiliki item yang dapat dicetak.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, index) => _itemRow(_items[index]),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 18),
          const Divider(height: 1, color: AppColors.slate200),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '$_selectedCount item dipilih',
                style: const TextStyle(
                  color: AppColors.slate600,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _printing || _items.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _selectedQuantities
                            ..clear()
                            ..addEntries(
                              _items.map(
                                (item) => MapEntry(item.id, item.quantity),
                              ),
                            );
                        });
                      },
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('Pilih Semua'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed:
                  _selectedCount > 0 && _targetPrinterId != null && !_printing
                  ? _print
                  : null,
              icon: _printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.soup_kitchen_outlined),
              label: Text(
                _printing
                    ? 'Mengirim ke Printer...'
                    : 'Cetak $_selectedCount Item Terpilih',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(OrderItem item) {
    final selected = _selectedQuantities[item.id] ?? 0;
    final isSelected = selected > 0;
    final optionNames = item.options
        .map((option) => option.optionName)
        .where((name) => name.trim().isNotEmpty)
        .join(', ');
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelected ? AppColors.primarySubtle : AppColors.slate50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? AppColors.primaryLight : AppColors.slate200,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.menuItem?.name ?? 'Item pesanan',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    'Jumlah pesanan: ${item.quantity}',
                    if (optionNames.isNotEmpty) optionNames,
                    if ((item.notes ?? '').trim().isNotEmpty)
                      'Catatan: ${item.notes!.trim()}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
                  tooltip: 'Kurangi jumlah',
                  visualDensity: VisualDensity.compact,
                  onPressed: selected > 0 && !_printing
                      ? () => setState(
                          () => _selectedQuantities[item.id] = selected - 1,
                        )
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
                  tooltip: 'Tambah jumlah',
                  visualDensity: VisualDensity.compact,
                  onPressed: selected < item.quantity && !_printing
                      ? () => setState(
                          () => _selectedQuantities[item.id] = selected + 1,
                        )
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
}

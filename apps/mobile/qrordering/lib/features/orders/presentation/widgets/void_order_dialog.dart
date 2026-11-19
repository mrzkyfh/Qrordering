import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/services/supabase_service.dart';
import '../../data/datasources/orders_datasource.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/void_receipt_print.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/transaction_journal_service.dart';

// ── Palet (spec desain) ──────────────────────────────────────────────────────
const _kRed = Color(0xFF0F766E);
const _kInk = Color(0xFF111111);
const _kBorder = Color(0xFFE8E8E8);

const _avatarGradients = [
  [Color(0xFF0F766E), Color(0xFF115E59)],
  [Color(0xFF2563EB), Color(0xFF1D4ED8)],
  [Color(0xFF7C3AED), Color(0xFF6D28D9)],
  [Color(0xFF1D9E75), Color(0xFF166534)],
];

/// Jenis aksi sensitif yang butuh otorisasi PIN atasan.
enum OrderActionType { voidOrder, refund }

typedef OrderActionStaffLoader =
    Future<List<Map<String, dynamic>>> Function(String outletId);

/// Tampilkan modal Batalkan Pesanan (Void). Mengembalikan true bila order
/// berhasil di-void (caller bisa menutup detail sheet & refresh).
Future<bool> showVoidOrderDialog(
  BuildContext context, {
  required Order order,
}) =>
    _showActionDialog(context, order: order, action: OrderActionType.voidOrder);

/// Tampilkan modal Refund Pesanan. Mengembalikan true bila berhasil.
Future<bool> showRefundOrderDialog(
  BuildContext context, {
  required Order order,
}) => _showActionDialog(context, order: order, action: OrderActionType.refund);

Future<bool> _showActionDialog(
  BuildContext context, {
  required Order order,
  required OrderActionType action,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: action == OrderActionType.voidOrder ? 'Void' : 'Refund',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => _VoidOrderDialog(order: order, action: action),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result == true;
}

/// Permukaan uji tanpa jaringan untuk memastikan dialog aksi sensitif tetap
/// dapat digunakan saat data otorisasi berhasil maupun gagal dimuat.
@visibleForTesting
Widget orderActionDialogForTesting({
  required Order order,
  required OrderActionType action,
  required OrderActionStaffLoader loadStaff,
}) => _VoidOrderDialog(order: order, action: action, loadStaff: loadStaff);

class _VoidOrderDialog extends StatefulWidget {
  final Order order;
  final OrderActionType action;
  final OrderActionStaffLoader? loadStaff;

  const _VoidOrderDialog({
    required this.order,
    required this.action,
    this.loadStaff,
  });
  @override
  State<_VoidOrderDialog> createState() => _VoidOrderDialogState();
}

class _VoidOrderDialogState extends State<_VoidOrderDialog>
    with SingleTickerProviderStateMixin {
  SupabaseService? _svc;
  OrdersDatasource? _ds;
  final _lainnyaCtrl = TextEditingController();

  List<Map<String, dynamic>> _staff = const [];
  bool _loadingStaff = true;
  String? _staffLoadError;

  int? _selectedIndex;
  bool _dropdownOpen = false;
  String _pin = '';
  String? _selectedAlasan; // batal_pesan | salah_proses | lainnya
  bool _loading = false;
  bool _isError = false;
  String? _errorMsg;

  late final AnimationController _shakeCtrl;

  bool get _isVoid => widget.action == OrderActionType.voidOrder;
  String get _title => _isVoid ? 'Batalkan Pesanan' : 'Refund Pesanan';
  String get _noLabel => _isVoid ? 'No Void' : 'No Refund';
  String get _confirmLabel => _isVoid ? 'Konfirmasi Void' : 'Konfirmasi Refund';
  String get _successMsg =>
      _isVoid ? 'Order berhasil di-void' : 'Order berhasil di-refund';
  String get _failMsg =>
      _isVoid ? 'Gagal membatalkan pesanan.' : 'Gagal melakukan refund.';
  SupabaseService get _service => _svc ??= SupabaseService();
  OrdersDatasource get _orders => _ds ??= OrdersDatasource();

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStaff());
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    _lainnyaCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStaff() async {
    if (mounted) {
      setState(() {
        _loadingStaff = true;
        _staffLoadError = null;
        _selectedIndex = null;
        _staff = const [];
      });
    }
    try {
      final all = widget.loadStaff != null
          ? await widget.loadStaff!(widget.order.outletId)
          : await _service.listClockinStaff(widget.order.outletId);
      // Hanya yang punya izin void (role manajer/admin/owner) & punya PIN.
      final filtered = all.where((s) {
        final role = (s['role'] ?? '') as String;
        final hasPin = s['has_pin'] == true;
        return hasPin &&
            (role == 'owner' || role == 'admin' || role == 'manajer');
      }).toList();
      if (mounted) setState(() => _staff = filtered);
    } catch (error) {
      if (mounted) {
        setState(() {
          _staffLoadError = humanizeError(
            error,
            fallback:
                'Data pemberi izin belum dapat dimuat. Periksa koneksi lalu coba lagi.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadingStaff = false);
    }
  }

  Map<String, dynamic>? get _selected =>
      _selectedIndex != null ? _staff[_selectedIndex!] : null;

  bool _canApprove(Map<String, dynamic> staff) =>
      _isVoid || staff['can_refund'] == true;

  bool get _hasEligibleStaff => _staff.any(_canApprove);

  String get _reasonText {
    switch (_selectedAlasan) {
      case 'batal_pesan':
        return 'Batal Pesan';
      case 'salah_proses':
        return 'Salah Proses';
      case 'lainnya':
        return _lainnyaCtrl.text.trim();
      default:
        return '';
    }
  }

  bool get _canConfirm {
    if (_selected == null || _pin.length != 4 || _selectedAlasan == null) {
      return false;
    }
    if (_selectedAlasan == 'lainnya' && _lainnyaCtrl.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  void _onKey(String key) {
    if (_loading) return;
    setState(() {
      _isError = false;
      _errorMsg = null;
      if (key == '<') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 4) {
        _pin += key;
      }
    });
  }

  Future<void> _confirm() async {
    if (!_canConfirm || _loading) return;
    setState(() => _loading = true);
    if (!ConnectivityService.instance.online.value) {
      final id =
          'manual-review-${_isVoid ? 'void' : 'refund'}-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
      final journal = TransactionJournalService.instance;
      await journal.enqueue(
        id: id,
        type: 'manual_review',
        payload: {
          'operation': _isVoid ? 'void_order' : 'refund_order',
          'orderId': widget.order.id,
          'reason': _reasonText,
          'approverId': _selected?['id'],
          'requiresPinWhenOnline': true,
        },
      );
      await journal.markNeedsReview(id, 'Menunggu verifikasi PIN saat online');
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Permintaan ${_isVoid ? 'void' : 'refund'} disimpan. Hubungkan internet lalu buka order dan verifikasi PIN kembali.',
          ),
        ),
      );
      return;
    }
    try {
      final approverId = _selected?['id'] as String?;
      if (_isVoid) {
        // Simpan pembatalan dahulu. Kegagalan printer setelah titik ini tidak
        // boleh membuat UI berkata Void gagal, karena transaksi sudah sah.
        final approverName = await _orders.voidOrder(
          widget.order.id,
          reason: _reasonText,
          approverPin: _pin,
          approverId: approverId,
        );
        await TransactionJournalService.instance.resolveManualReviews(
          operation: 'void_order',
          orderId: widget.order.id,
        );
        if (!mounted) return;
        final auth = context.read<AuthBloc>().state;
        final printedBy = auth is AuthAuthenticated
            ? auth.profile.fullName
            : approverName;
        PrintOutcome? voidPrintResult;
        final printErrors = <String>[];
        try {
          voidPrintResult = await printVoidReceipt(
            order: widget.order,
            reason: _reasonText,
            approverName: printedBy,
          );
        } catch (_) {
          printErrors.add('Struk Void Kasir Utama belum dapat dibuat.');
        }

        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context, true);
        final messages = <String>['Order berhasil di-void.'];
        if (voidPrintResult == PrintOutcome.printed) {
          messages.add('Struk Void dicetak di Kasir Utama.');
        } else if (voidPrintResult == PrintOutcome.failed) {
          messages.add('Struk Void Kasir Utama masuk antrean cetak.');
        } else if (voidPrintResult == PrintOutcome.skipped) {
          messages.add('Printer Kasir Utama belum dikonfigurasi.');
        }
        messages.addAll(printErrors);
        messenger.showSnackBar(
          SnackBar(
            content: Text(messages.join(' ')),
            backgroundColor: _kInk,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
        return;
      } else {
        await _orders.refundOrder(
          widget.order.id,
          reason: _reasonText,
          approverPin: _pin,
          approverId: approverId,
        );
        await TransactionJournalService.instance.resolveManualReviews(
          operation: 'refund_order',
          orderId: widget.order.id,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_successMsg),
          backgroundColor: _kInk,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    } catch (e) {
      if (isBackendTransportFailure(e)) {
        final id =
            'manual-review-${_isVoid ? 'void' : 'refund'}-${widget.order.id}-${DateTime.now().microsecondsSinceEpoch}';
        final journal = TransactionJournalService.instance;
        await journal.enqueue(
          id: id,
          type: 'manual_review',
          payload: {
            'operation': _isVoid ? 'void_order' : 'refund_order',
            'orderId': widget.order.id,
            'reason': _reasonText,
            'approverId': _selected?['id'],
            'requiresPinWhenOnline': true,
            // PIN is intentionally never persisted.
          },
        );
        await journal.markNeedsReview(id, e);
      }
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final isPinError = msg.contains('pin') || msg.contains('berwenang');
      setState(() {
        _loading = false;
        _isError = true;
        _errorMsg = isPinError
            ? 'PIN salah, coba lagi'
            : humanizeError(e, fallback: _failMsg);
      });
      _shakeCtrl.forward(from: 0);
      if (isPinError) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) {
            setState(() {
              _pin = '';
              _isError = false;
            });
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(humanizeError(e, fallback: _failMsg)),
            backgroundColor: const Color(0xFF991B1B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(400.0, MediaQuery.of(context).size.width - 48);
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            Flexible(child: SingleChildScrollView(child: _body())),
            _footer(),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _kInk,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '$_noLabel: ${widget.order.orderNumber}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF999999),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.close,
                size: 12,
                color: Color(0xFF888888),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────
  Widget _body() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoDana(),
          const SizedBox(height: 12),
          _label('Otorisasi Oleh'),
          const SizedBox(height: 5),
          _authDropdown(),
          // Tampilkan opsi saat dropdown dibuka, atau pesan kosong/loading
          // saat belum ada staff berwenang (agar tidak "buntu" tanpa info).
          if (_dropdownOpen || _loadingStaff || _staff.isEmpty) _authOptions(),
          if (!_isVoid &&
              !_loadingStaff &&
              _staffLoadError == null &&
              !_hasEligibleStaff)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Tidak ada staf yang memiliki akses refund.',
                style: TextStyle(fontSize: 11, color: _kRed),
              ),
            ),
          const SizedBox(height: 12),
          _label('PIN Otorisasi'),
          const SizedBox(height: 5),
          _pinBox(),
          const SizedBox(height: 12),
          _label(_isVoid ? 'Alasan Pembatalan' : 'Alasan Refund'),
          const SizedBox(height: 5),
          _alasanGrid(),
          if (_selectedAlasan == 'lainnya') ...[
            const SizedBox(height: 6),
            _lainnyaField(),
          ],
        ],
      ),
    );
  }

  Widget _label(String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: Color(0xFF555555),
    ),
  );

  Widget _infoDana() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final label = const Text(
            'Jumlah Dana yang Dikembalikan',
            style: TextStyle(fontSize: 10, color: Color(0xFF999999)),
          );
          final amount = Text(
            CurrencyFormatter.format(widget.order.totalAmount),
            maxLines: 1,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _kInk,
            ),
          );
          if (constraints.maxWidth < 250) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [label, const SizedBox(height: 3), amount],
            );
          }
          return Row(
            children: [
              Expanded(child: label),
              const SizedBox(width: 8),
              amount,
            ],
          );
        },
      ),
    );
  }

  // ── Dropdown otorisasi ──────────────────────────────────────────────────
  Widget _authDropdown() {
    final s = _selected;
    return GestureDetector(
      onTap: _staff.isEmpty
          ? null
          : () => setState(() => _dropdownOpen = !_dropdownOpen),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kBorder, width: 1.5),
        ),
        child: Row(
          children: [
            _avatar(
              s != null ? (s['full_name'] ?? '?') as String : '?',
              _selectedIndex ?? 0,
              26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: s != null
                  ? Text(
                      (s['full_name'] ?? '-') as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _kInk,
                      ),
                    )
                  : const Text(
                      'Pilih staff',
                      style: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
                    ),
            ),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: Color(0xFFBBBBBB),
            ),
          ],
        ),
      ),
    );
  }

  Widget _authOptions() {
    if (_loadingStaff) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_staffLoadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Text(
              _staffLoadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: _kRed),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _loadStaff,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Coba Lagi'),
            ),
          ],
        ),
      );
    }
    if (_staff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            _isVoid
                ? 'Tidak ada staf dengan izin void'
                : 'Tidak ada staf dengan izin refund',
            style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder, width: 0.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _staff.length,
        itemBuilder: (_, i) {
          final s = _staff[i];
          final name = (s['full_name'] ?? '-') as String;
          final canApprove = _canApprove(s);
          final isLast = i == _staff.length - 1;
          return InkWell(
            onTap: canApprove
                ? () => setState(() {
                    _selectedIndex = i;
                    _dropdownOpen = false;
                    _pin = '';
                    _isError = false;
                    _errorMsg = null;
                  })
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                border: isLast
                    ? null
                    : const Border(
                        bottom: BorderSide(
                          color: Color(0xFFF5F5F5),
                          width: 0.5,
                        ),
                      ),
              ),
              child: Row(
                children: [
                  _avatar(name, i, 26),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: canApprove ? _kInk : const Color(0xFFAAAAAA),
                          ),
                        ),
                        if (!canApprove)
                          const Text(
                            'Tidak memiliki akses refund',
                            style: TextStyle(
                              fontSize: 9,
                              color: Color(0xFFAAAAAA),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!canApprove)
                    const Icon(
                      Icons.lock_outline,
                      size: 15,
                      color: Color(0xFFAAAAAA),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF3DE),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        'PIN ✓',
                        style: TextStyle(fontSize: 9, color: Color(0xFF27500A)),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _avatar(String name, int index, double size) {
    final g = _avatarGradients[index % _avatarGradients.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size == 26 ? 6 : 7),
        gradient: LinearGradient(
          colors: g,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  // ── PIN ─────────────────────────────────────────────────────────────────
  Widget _pinBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          _dots(),
          const SizedBox(height: 8),
          _numpad(),
          if (_errorMsg != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _errorMsg!,
                style: const TextStyle(fontSize: 11, color: _kRed),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dots() {
    return AnimatedBuilder(
      animation: _shakeCtrl,
      builder: (context, child) {
        final dx = _isError
            ? math.sin(_shakeCtrl.value * math.pi * 4) * 6
            : 0.0;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (i) {
          final filled = i < _pin.length;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 5),
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isError
                  ? _kRed.withValues(alpha: 0.3)
                  : (filled ? _kRed : Colors.transparent),
              border: Border.all(
                color: _isError
                    ? _kRed.withValues(alpha: 0.3)
                    : (filled ? _kRed : const Color(0xFFD0D0D0)),
                width: 2,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _numpad() {
    Widget btn(String n) => _NumKey(label: n, onTap: () => _onKey(n));
    Widget row(List<Widget> kids) {
      final spaced = <Widget>[];
      for (var i = 0; i < kids.length; i++) {
        spaced.add(Expanded(child: kids[i]));
        if (i < kids.length - 1) spaced.add(const SizedBox(width: 4));
      }
      return Row(children: spaced);
    }

    return Column(
      children: [
        row([btn('1'), btn('2'), btn('3')]),
        const SizedBox(height: 4),
        row([btn('4'), btn('5'), btn('6')]),
        const SizedBox(height: 4),
        row([btn('7'), btn('8'), btn('9')]),
        const SizedBox(height: 4),
        row([
          const SizedBox(),
          btn('0'),
          _NumKey(label: '<', onTap: () => _onKey('<')),
        ]),
      ],
    );
  }

  // ── Alasan ────────────────────────────────────────────────────────────────
  Widget _alasanGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _alasanBtn('batal_pesan', 'Batal Pesan')),
            const SizedBox(width: 6),
            Expanded(child: _alasanBtn('salah_proses', 'Salah Proses')),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: _alasanBtn('lainnya', 'Lainnya'),
        ),
      ],
    );
  }

  Widget _alasanBtn(String value, String label) {
    final active = _selectedAlasan == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedAlasan = value),
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFFECEC) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? _kRed : const Color(0xFFE5E5E5),
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: active ? const Color(0xFF115E59) : const Color(0xFF555555),
          ),
        ),
      ),
    );
  }

  Widget _lainnyaField() {
    return TextField(
      controller: _lainnyaCtrl,
      minLines: 2,
      maxLines: 3,
      style: const TextStyle(fontSize: 12, color: _kInk),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Tuliskan alasan...',
        hintStyle: const TextStyle(fontSize: 11, color: Color(0xFFCCCCCC)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E5E5), width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E5E5), width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kRed, width: 1.5),
        ),
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────
  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0F0F0), width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: GestureDetector(
              onTap: _loading ? null : () => Navigator.pop(context),
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFE0E0E0),
                    width: 1.5,
                  ),
                ),
                child: const Text(
                  'Batal',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF555555),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: _canConfirm && !_loading ? _confirm : null,
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _canConfirm ? _kRed : const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _confirmLabel,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NumKey({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isBackspace = label == '<';
    return Material(
      color: isBackspace ? const Color(0xFFF0F0F0) : Colors.white,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
          ),
          child: isBackspace
              ? const Icon(
                  Icons.backspace_outlined,
                  size: 14,
                  color: Color(0xFF666666),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _kInk,
                  ),
                ),
        ),
      ),
    );
  }
}

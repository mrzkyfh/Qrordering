import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'kasir_shell.dart';
import '../bloc/shift_bloc.dart';
import '../../data/datasources/shift_datasource.dart';
import '../../../../shared/models/shift.dart';
import '../../../../shared/models/cash_movement.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/shift_close_report.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/shift_close_report_print.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/utils/thousands_formatter.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Palet Shift Kasir (beraksen hijau/merah + bar gelap, sesuai spec).
class _SC {
  _SC._();
  static const bg = Color(0xFFF4F5F7);
  static const card = Colors.white;
  static const border = Color(0xFFEEEEEE);
  static const ink = Color(0xFF111111);
  static const sec = Color(0xFF555555);
  static const ter = Color(0xFF999999);
  static const green = Color(0xFF16A34A);
  static const greenBright = Color(0xFF22C55E);
  static const greenBg = Color(0xFFF0FDF4);
  static const red = Color(0xFFDC2626);
  static const redBg = Color(0xFFFFF1F1);
  static const dark = Color(0xFF1A1A1A);
}

const _expenseCategories = <String, String>{
  'bahan_baku': 'Bahan Baku',
  'operasional': 'Operasional',
  'gaji': 'Gaji',
  'peralatan': 'Peralatan',
  'marketing': 'Pemasaran',
  'lain_lain': 'Lain-lain',
};

@visibleForTesting
bool canManageCashMovements(UserRole? role) =>
    role == UserRole.owner ||
    role == UserRole.admin ||
    role == UserRole.manajer;

class ShiftPage extends StatefulWidget {
  const ShiftPage({super.key});
  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthBloc>().state;
    if (auth is AuthAuthenticated) {
      context.read<ShiftBloc>().add(
        ShiftLoadRequested(auth.profile.outletId ?? '', auth.profile.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) => const _ShiftView();
}

class _ShiftView extends StatelessWidget {
  const _ShiftView();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final canManageCash = canManageCashMovements(
      auth is AuthAuthenticated ? auth.profile.role : null,
    );
    return BlocListener<ShiftBloc, ShiftState>(
      listenWhen: (previous, current) =>
          previous.closeReport?.shiftId != current.closeReport?.shiftId &&
          current.closeReport != null,
      listener: (context, state) async {
        final report = state.closeReport;
        if (report == null) return;
        await _modal(context, (_) => _CloseReportModal(report: report));
        if (context.mounted) {
          context.read<ShiftBloc>().add(ShiftCloseReportDismissed());
        }
      },
      child: Scaffold(
        backgroundColor: _SC.bg,
        body: Column(
          children: [
            // Header
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: _SC.border)),
              ),
              child: Row(
                children: [
                  InkWell(
                    onTap: KasirShell.openMenu,
                    borderRadius: BorderRadius.circular(6),
                    child: const SizedBox(
                      width: 30,
                      height: 30,
                      child: Icon(
                        Icons.menu,
                        size: 20,
                        color: Color(0xFF666666),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Shift Kasir',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _SC.ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<ShiftBloc, ShiftState>(
                builder: (context, state) {
                  if (state.loading) {
                    return const Center(
                      child: CircularProgressIndicator(color: _SC.ink),
                    );
                  }
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: RefreshIndicator(
                        onRefresh: () async => context.read<ShiftBloc>().add(
                          ShiftLoadRequested(state.outletId, state.kasirId),
                        ),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                          children: [
                            if (state.error != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _SC.redBg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: _SC.red.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Text(
                                  state.error!,
                                  style: const TextStyle(
                                    color: _SC.red,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            state.activeShift != null
                                ? _ActiveShiftCard(
                                    shift: state.activeShift!,
                                    canManageCash: canManageCash,
                                    canCloseShift: !canManageCash,
                                  )
                                : const _NoShiftCard(),
                            if (state.recentShifts.isNotEmpty) ...[
                              const SizedBox(height: 24),
                              const Text(
                                'RIWAYAT 7 HARI TERAKHIR',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF888888),
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 14),
                              _HistoryCard(
                                shifts: state.recentShifts,
                                canViewCashMovements: canManageCash,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Section shift aktif (dipakai halaman Shift & Laporan → Kasir) ────────────
class ShiftActiveSection extends StatelessWidget {
  const ShiftActiveSection({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final canManageCash = canManageCashMovements(
      auth is AuthAuthenticated ? auth.profile.role : null,
    );
    return BlocBuilder<ShiftBloc, ShiftState>(
      builder: (context, state) {
        if (state.loading) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(color: _SC.ink)),
          );
        }
        return state.activeShift != null
            ? _ActiveShiftCard(
                shift: state.activeShift!,
                canManageCash: canManageCash,
                canCloseShift: !canManageCash,
              )
            : const _NoShiftCard();
      },
    );
  }
}

/// Pemilih shift kasir aktif untuk Owner/Admin/Manajer.
///
/// Role manajemen tidak membuka shift atas namanya sendiri. Karena itu aksi
/// Kas Masuk/Keluar harus diarahkan secara eksplisit ke shift kasir yang dipilih.
class ManagementCashMovementSection extends StatefulWidget {
  final String outletId;
  final ShiftDatasource? datasource;

  const ManagementCashMovementSection({
    super.key,
    required this.outletId,
    this.datasource,
  });

  @override
  State<ManagementCashMovementSection> createState() =>
      _ManagementCashMovementSectionState();
}

class _ManagementCashMovementSectionState
    extends State<ManagementCashMovementSection> {
  late final ShiftDatasource _datasource =
      widget.datasource ?? ShiftDatasource();
  late final ShiftBloc _targetBloc = ShiftBloc(datasource: _datasource);
  List<Shift> _shifts = const [];
  String? _selectedId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ManagementCashMovementSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outletId != widget.outletId) _load();
  }

  @override
  void dispose() {
    _targetBloc.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.outletId.isEmpty) {
      setState(() {
        _loading = false;
        _shifts = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shifts = await _datasource.fetchActiveShiftsForManagement(
        widget.outletId,
      );
      if (!mounted) return;
      final retained = shifts.any((shift) => shift.id == _selectedId)
          ? _selectedId
          : shifts.isEmpty
          ? null
          : shifts.first.id;
      setState(() {
        _shifts = shifts;
        _selectedId = retained;
        _loading = false;
      });
      final target = _selectedShift;
      if (target != null) {
        _targetBloc.add(ShiftManagementTargetSelected(target));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = humanizeError(
          error,
          fallback: 'Shift kasir aktif belum dapat dimuat.',
        );
      });
    }
  }

  Shift? get _selectedShift {
    for (final shift in _shifts) {
      if (shift.id == _selectedId) return shift;
    }
    return null;
  }

  void _select(String? shiftId) {
    if (shiftId == null || shiftId == _selectedId) return;
    setState(() => _selectedId = shiftId);
    final target = _selectedShift;
    if (target != null) {
      _targetBloc.add(ShiftManagementTargetSelected(target));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator(color: _SC.ink)),
      );
    }
    if (_error != null) {
      return _managementMessageCard(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Coba Lagi'),
        ),
      );
    }
    if (_shifts.isEmpty) {
      return _managementMessageCard(
        icon: Icons.point_of_sale_outlined,
        message: 'Tidak ada shift kasir yang sedang aktif.',
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Muat Ulang'),
        ),
      );
    }

    final selected = _selectedShift!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Kelola Kas Shift',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _SC.ink,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Pilih kasir sebelum mencatat kas masuk atau keluar.',
                    style: TextStyle(fontSize: 12.5, color: _SC.ter),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Muat ulang shift aktif',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: const Key('management-shift-selector'),
          initialValue: selected.id,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Shift kasir aktif',
            prefixIcon: const Icon(Icons.badge_outlined),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _SC.border),
            ),
          ),
          items: _shifts
              .map(
                (shift) => DropdownMenuItem<String>(
                  value: shift.id,
                  child: Text(
                    '${shift.cashierName ?? 'Kasir'} · mulai '
                    '${DateFormat('HH:mm').format(shift.startTime.toLocal())}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _select,
        ),
        const SizedBox(height: 12),
        BlocProvider.value(
          value: _targetBloc,
          child: BlocBuilder<ShiftBloc, ShiftState>(
            builder: (context, state) {
              if (state.loading || state.activeShift?.id != selected.id) {
                return const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                    child: CircularProgressIndicator(color: _SC.ink),
                  ),
                );
              }
              return Column(
                children: [
                  if (state.error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _SC.redBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _SC.red.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: _SC.red, fontSize: 13),
                      ),
                    ),
                  _ActiveShiftCard(
                    shift: selected,
                    canManageCash: true,
                    canCloseShift: false,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _managementMessageCard({
    required IconData icon,
    required String message,
    required Widget action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _SC.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: _SC.ter),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _SC.sec),
          ),
          const SizedBox(height: 14),
          action,
        ],
      ),
    );
  }
}

// ── Dot berdenyut ────────────────────────────────────────────────────────────
class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value;
        return SizedBox(
          width: 18,
          height: 18,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 8 + t * 10,
                height: 8 + t * 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _SC.greenBright.withValues(alpha: (1 - t) * 0.4),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: _SC.greenBright,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Card jika tidak ada shift aktif ──────────────────────────────────────────
class _NoShiftCard extends StatelessWidget {
  const _NoShiftCard();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _SC.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _SC.border),
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(Icons.timer_outlined, size: 52, color: Color(0xFFCCCCCC)),
          const SizedBox(height: 12),
          const Text(
            'Kasir belum dibuka',
            style: TextStyle(color: _SC.sec, fontSize: 15),
          ),
          const SizedBox(height: 6),
          const Text(
            'Anda tetap dapat melihat aplikasi. Buka kasir hanya saat akan mulai menerima pembayaran.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _SC.ter, fontSize: 12),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: BlocBuilder<ShiftBloc, ShiftState>(
              builder: (context, state) => FilledButton.icon(
                onPressed: state.submitting
                    ? null
                    : () => _showOpenModal(context),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: const Text('Buka Kasir'),
                style: FilledButton.styleFrom(
                  backgroundColor: _SC.ink,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
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

// ── Card shift aktif (dark bar + stats + aksi) ───────────────────────────────
@visibleForTesting
Widget activeShiftCardForTesting({
  required Shift shift,
  required UserRole role,
}) => _ActiveShiftCard(
  shift: shift,
  canManageCash: canManageCashMovements(role),
  canCloseShift: role == UserRole.kasir,
);

class _ActiveShiftCard extends StatelessWidget {
  final Shift shift;
  final bool canManageCash;
  final bool canCloseShift;
  const _ActiveShiftCard({
    required this.shift,
    required this.canManageCash,
    required this.canCloseShift,
  });

  @override
  Widget build(BuildContext context) {
    final dur = DateTime.now().difference(shift.startTime);
    final h = dur.inHours;
    final m = dur.inMinutes % 60;
    final elapsed = h > 0 ? '${h}j ${m}m' : '${m}m';
    final startFmt = DateFormat(
      'HH:mm, d MMM yyyy',
      'id_ID',
    ).format(shift.startTime.toLocal());

    return Container(
      decoration: BoxDecoration(
        color: _SC.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Bar gelap
          Container(
            color: _SC.dark,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                const _PulseDot(),
                const SizedBox(width: 8),
                const Text(
                  'Shift Berjalan',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _SC.greenBright,
                    letterSpacing: 0.3,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        elapsed,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Stats
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0))),
            ),
            child: Row(
              children: [
                Expanded(child: _stat('Mulai', startFmt)),
                Container(
                  height: 34,
                  width: 1,
                  color: const Color(0xFFF0F0F0),
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                ),
                Expanded(
                  child: _stat(
                    'Kas Awal',
                    CurrencyFormatter.format(shift.openingCash),
                  ),
                ),
              ],
            ),
          ),
          // Kas masuk/keluar + tutup
          BlocBuilder<ShiftBloc, ShiftState>(
            builder: (context, state) {
              return Column(
                children: [
                  if (canManageCash) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _cashBtn(
                            context,
                            icon: Icons.add,
                            label: 'Kas Masuk',
                            color: _SC.green,
                            hoverBg: _SC.greenBg,
                            borderRight: true,
                            onTap: state.submitting
                                ? null
                                : () => _showCashModal(context, 'in'),
                          ),
                        ),
                        Expanded(
                          child: _cashBtn(
                            context,
                            icon: Icons.remove,
                            label: 'Kas Keluar',
                            color: _SC.red,
                            hoverBg: _SC.redBg,
                            borderRight: false,
                            onTap: state.submitting
                                ? null
                                : () => _showCashModal(context, 'out'),
                          ),
                        ),
                      ],
                    ),
                    if (state.cashMovements.isNotEmpty)
                      Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Color(0xFFF0F0F0)),
                          ),
                        ),
                        child: Column(
                          children: state.cashMovements
                              .take(5)
                              .map((mv) => _movementRow(mv))
                              .toList(),
                        ),
                      ),
                  ],
                  if (canCloseShift)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: state.submitting
                              ? null
                              : () => _showCloseModal(context, shift),
                          icon: state.submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                ),
                          label: const Text('Tutup Shift'),
                          style: FilledButton.styleFrom(
                            backgroundColor: _SC.red,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _SC.ter,
          letterSpacing: 0.5,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: _SC.ink,
        ),
      ),
    ],
  );

  Widget _cashBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required Color hoverBg,
    required bool borderRight,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        hoverColor: hoverBg,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: borderRight
                ? const Border(right: BorderSide(color: Color(0xFFF0F0F0)))
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _movementRow(CashMovement mv) {
    final color = mv.isIn ? _SC.green : _SC.red;
    final time = DateFormat('HH:mm', 'id_ID').format(mv.createdAt.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      child: Row(
        children: [
          Icon(
            mv.isIn ? Icons.south_west : Icons.north_east,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              (mv.note?.isNotEmpty ?? false)
                  ? mv.note!
                  : (mv.isIn ? 'Kas masuk' : 'Kas keluar'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: _SC.sec),
            ),
          ),
          Text(time, style: const TextStyle(fontSize: 12, color: _SC.ter)),
          const SizedBox(width: 10),
          Text(
            (mv.isIn ? '+' : '−') + CurrencyFormatter.format(mv.amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Riwayat ──────────────────────────────────────────────────────────────────
class _HistoryCard extends StatelessWidget {
  final List<Shift> shifts;
  final bool canViewCashMovements;
  const _HistoryCard({
    required this.shifts,
    required this.canViewCashMovements,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _SC.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < shifts.length; i++)
            _HistoryTile(
              shift: shifts[i],
              last: i == shifts.length - 1,
              canViewCashMovements: canViewCashMovements,
            ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Shift shift;
  final bool last;
  final bool canViewCashMovements;
  const _HistoryTile({
    required this.shift,
    required this.last,
    required this.canViewCashMovements,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('d MMM', 'id_ID').format(shift.startTime.toLocal());
    final start = DateFormat('HH:mm').format(shift.startTime.toLocal());
    final end = shift.endTime != null
        ? DateFormat('HH:mm').format(shift.endTime!.toLocal())
        : '—';
    final diff = shift.cashDifference ?? 0;
    final pos = diff >= 0;
    final badge = diff == 0
        ? 'Rp 0'
        : (pos ? '+' : '−') + CurrencyFormatter.format(diff.abs());

    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _showDetailModal(
          context,
          shift,
          canViewCashMovements: canViewCashMovements,
        ),
        hoverColor: const Color(0xFFFAFAFA),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            border: last
                ? null
                : const Border(bottom: BorderSide(color: Color(0xFFF5F5F5))),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  date,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _SC.ter,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '$start – $end',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _SC.sec,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: pos ? _SC.greenBg : _SC.redBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: pos ? _SC.green : _SC.red,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: Color(0xFFCCCCCC),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══ MODALS ═══════════════════════════════════════════════════════════════════

/// `showDialog` mendorong route ke ROOT navigator, sedangkan `Navigator.pop(
/// context)` dengan context halaman akan menemukan Navigator ShellRoute
/// (nested) → pop route yang salah / "Bad state: No element". Karena itu isi
/// modal dibangun lewat builder agar tombol memakai context dialog sendiri.
Future<T?> _modal<T>(BuildContext context, WidgetBuilder builder) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: builder,
  );
}

Widget _panel({required Widget child}) => Dialog(
  backgroundColor: Colors.white,
  insetPadding: const EdgeInsets.all(20),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  clipBehavior: Clip.antiAlias,
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 480),
    child: child,
  ),
);

InputDecoration _noteDecoration() => InputDecoration(
  isDense: true,
  filled: true,
  fillColor: const Color(0xFFFAFAFA),
  hintText: 'Opsional',
  hintStyle: const TextStyle(color: _SC.ter),
  contentPadding: const EdgeInsets.all(13),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
  ),
);

Widget _fieldLabel(String t) => Padding(
  padding: const EdgeInsets.only(bottom: 7),
  child: Text(
    t.toUpperCase(),
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: _SC.ter,
      letterSpacing: 0.5,
    ),
  ),
);

/// Input nominal: prefix "Rp" + angka, border aksen.
Widget _amountField(
  TextEditingController c,
  Color accent, {
  bool autofocus = false,
}) {
  return Container(
    decoration: BoxDecoration(
      color: const Color(0xFFFAFAFA),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: accent, width: 1.5),
    ),
    clipBehavior: Clip.antiAlias,
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(
              right: BorderSide(color: Color(0xFFEEEEEE), width: 1.5),
            ),
          ),
          child: const Text(
            'Rp',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _SC.ter,
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: c,
            autofocus: autofocus,
            keyboardType: TextInputType.number,
            inputFormatters: [ThousandsInputFormatter()],
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: _SC.ink,
            ),
            decoration: const InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 13,
                vertical: 14,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Footer 2 tombol (1fr Batal | 2fr Aksi).
Widget _modalFooter({
  required VoidCallback onCancel,
  required VoidCallback onAction,
  required String actionLabel,
  required Color accent,
}) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: onCancel,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF666666),
            side: const BorderSide(color: Color(0xFFE5E5E5), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: const Text('Batal'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 2,
        child: FilledButton(
          onPressed: onAction,
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Text(actionLabel),
        ),
      ),
    ],
  );
}

Widget _modalHeader(
  IconData icon,
  Color iconBg,
  Color iconColor,
  String title,
) {
  return Row(
    children: [
      Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: iconBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 19, color: iconColor),
      ),
      const SizedBox(width: 12),
      Text(
        title,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: _SC.ink,
        ),
      ),
    ],
  );
}

// ── Modal Kas Masuk / Keluar ─────────────────────────────────────────────────
void _showCashModal(BuildContext context, String type) {
  final bloc = context.read<ShiftBloc>();
  final isIn = type == 'in';
  final accent = isIn ? _SC.green : _SC.red;
  final amount = TextEditingController();
  final note = TextEditingController();
  var expenseCategory = 'operasional';

  _modal(
    context,
    (ctx) => BlocProvider.value(
      value: bloc,
      child: StatefulBuilder(
        builder: (ctx, setModalState) => _panel(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _modalHeader(
                  isIn ? Icons.add : Icons.remove,
                  isIn ? _SC.greenBg : _SC.redBg,
                  accent,
                  isIn ? 'Kas Masuk' : 'Kas Keluar',
                ),
                const SizedBox(height: 8),
                Text(
                  isIn
                      ? 'Tambahan uang tunai ke laci, misalnya tambahan modal.'
                      : 'Uang keluar dari laci dan otomatis masuk ke laporan Pengeluaran.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: _SC.ter,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                _fieldLabel('Nominal'),
                _amountField(amount, accent, autofocus: true),
                if (!isIn) ...[
                  const SizedBox(height: 14),
                  _fieldLabel('Kategori Pengeluaran'),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: _SC.border),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: expenseCategory,
                        isExpanded: true,
                        items: _expenseCategories.entries
                            .map(
                              (entry) => DropdownMenuItem<String>(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setModalState(() => expenseCategory = value);
                          }
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _fieldLabel('Catatan'),
                TextField(controller: note, decoration: _noteDecoration()),
                const SizedBox(height: 20),
                _modalFooter(
                  accent: accent,
                  actionLabel: isIn ? 'Simpan Kas Masuk' : 'Simpan Kas Keluar',
                  onCancel: () => Navigator.pop(ctx),
                  onAction: () {
                    final val = parseThousands(amount.text);
                    if (val <= 0) return;
                    bloc.add(
                      ShiftCashMovementRequested(
                        type,
                        val,
                        note.text.isEmpty ? null : note.text,
                        expenseCategory: expenseCategory,
                      ),
                    );
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ── Modal Tutup Shift ────────────────────────────────────────────────────────
void _showCloseModal(BuildContext context, Shift shift) {
  final bloc = context.read<ShiftBloc>();
  final cash = TextEditingController();
  final note = TextEditingController();

  _modal(
    context,
    (ctx) => BlocProvider.value(
      value: bloc,
      child: _panel(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _modalHeader(
                Icons.remove_circle_outline,
                _SC.redBg,
                _SC.red,
                'Tutup Shift',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Kas awal:',
                      style: TextStyle(fontSize: 13, color: _SC.ter),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      CurrencyFormatter.format(shift.openingCash),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _fieldLabel('Kas Akhir (Rp)'),
              _amountField(cash, _SC.red, autofocus: true),
              const SizedBox(height: 14),
              _fieldLabel('Catatan'),
              TextField(controller: note, decoration: _noteDecoration()),
              const SizedBox(height: 20),
              _modalFooter(
                accent: _SC.red,
                actionLabel: 'Tutup Shift',
                onCancel: () => Navigator.pop(ctx),
                onAction: () {
                  if (cash.text.trim().isEmpty) return;
                  bloc.add(
                    ShiftCloseRequested(
                      parseThousands(cash.text),
                      note.text.isEmpty ? null : note.text,
                    ),
                  );
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── Modal Buka Kasir ─────────────────────────────────────────────────────────
void _showOpenModal(BuildContext context) {
  final bloc = context.read<ShiftBloc>();
  final cash = TextEditingController();

  _modal(
    context,
    (ctx) => BlocProvider.value(
      value: bloc,
      child: _panel(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _modalHeader(
                Icons.play_arrow,
                _SC.greenBg,
                _SC.green,
                'Buka Kasir',
              ),
              const SizedBox(height: 16),
              _fieldLabel('Kas Awal (Rp)'),
              _amountField(cash, _SC.green, autofocus: true),
              const SizedBox(height: 20),
              _modalFooter(
                accent: _SC.ink,
                actionLabel: 'Buka Kasir',
                onCancel: () => Navigator.pop(ctx),
                onAction: () {
                  bloc.add(ShiftOpenRequested(parseThousands(cash.text)));
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── Modal Detail Shift ───────────────────────────────────────────────────────
void _showDetailModal(
  BuildContext context,
  Shift shift, {
  required bool canViewCashMovements,
}) {
  _modal(
    context,
    (_) =>
        _DetailModal(shift: shift, canViewCashMovements: canViewCashMovements),
  );
}

class _DetailModal extends StatefulWidget {
  final Shift shift;
  final bool canViewCashMovements;
  const _DetailModal({required this.shift, required this.canViewCashMovements});
  @override
  State<_DetailModal> createState() => _DetailModalState();
}

class _DetailModalState extends State<_DetailModal> {
  final _ds = ShiftDatasource();
  List<CashMovement>? _movements;
  bool _loadingReport = false;

  @override
  void initState() {
    super.initState();
    if (!widget.canViewCashMovements) {
      _movements = const [];
      return;
    }
    _ds
        .fetchCashMovements(widget.shift.id)
        .then((m) {
          if (mounted) setState(() => _movements = m);
        })
        .catchError((_) {
          if (mounted) setState(() => _movements = <CashMovement>[]);
        });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shift;
    final date = DateFormat(
      'd MMM yyyy',
      'id_ID',
    ).format(s.startTime.toLocal());
    final start = DateFormat('HH:mm').format(s.startTime.toLocal());
    final end = s.endTime != null
        ? DateFormat('HH:mm').format(s.endTime!.toLocal())
        : '—';
    final dur = (s.endTime ?? DateTime.now()).difference(s.startTime);
    final durStr = '${dur.inHours}j ${dur.inMinutes % 60}m';
    final diff = s.cashDifference ?? 0;
    final pos = diff >= 0;

    return _panel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header gelap
          Container(
            color: _SC.dark,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DETAIL SHIFT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF888888),
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$date · $start – $end',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.pop(context),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Stats 3 kolom
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0))),
            ),
            child: Row(
              children: [
                Expanded(child: _detailStat('Durasi', durStr)),
                Expanded(
                  child: _detailStat(
                    'Kas Awal',
                    CurrencyFormatter.format(s.openingCash),
                  ),
                ),
                Expanded(
                  child: _detailStat(
                    'Kas Akhir',
                    s.closingCash != null
                        ? CurrencyFormatter.format(s.closingCash!)
                        : '—',
                  ),
                ),
              ],
            ),
          ),
          // Transaksi
          if (widget.canViewCashMovements)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'TRANSAKSI',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFBBBBBB),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_movements == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _SC.ink,
                            ),
                          ),
                        ),
                      )
                    else if (_movements!.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Tidak ada kas masuk/keluar.',
                          style: TextStyle(fontSize: 13, color: _SC.ter),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: _movements!.map(_detailMovement).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // Footer selisih
          Container(
            width: double.infinity,
            color: const Color(0xFFFAFAFA),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Selisih Bersih',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF666666),
                  ),
                ),
                Text(
                  diff == 0
                      ? 'Rp 0'
                      : (pos ? '+' : '−') +
                            CurrencyFormatter.format(diff.abs()),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: pos ? _SC.green : _SC.red,
                  ),
                ),
              ],
            ),
          ),
          if (s.endTime != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loadingReport ? null : _openReport,
                  style: FilledButton.styleFrom(
                    backgroundColor: _SC.ink,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: _loadingReport
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.receipt_long_outlined, size: 18),
                  label: Text(
                    _loadingReport
                        ? 'Memuat Laporan...'
                        : 'Lihat dan Cetak Laporan',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openReport() async {
    setState(() => _loadingReport = true);
    try {
      final report = await _ds.fetchCloseReport(widget.shift.id);
      if (!mounted) return;
      await _modal(context, (_) => _CloseReportModal(report: report));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Laporan belum dapat dimuat.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingReport = false);
    }
  }

  Widget _detailStat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _SC.ter,
          letterSpacing: 0.3,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: _SC.ink,
        ),
      ),
    ],
  );

  Widget _detailMovement(CashMovement mv) {
    final color = mv.isIn ? _SC.green : _SC.red;
    final bg = mv.isIn ? _SC.greenBg : _SC.redBg;
    final time = DateFormat('HH:mm', 'id_ID').format(mv.createdAt.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              mv.isIn ? Icons.add : Icons.remove,
              size: 15,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (mv.note?.isNotEmpty ?? false)
                      ? mv.note!
                      : (mv.isIn ? 'Kas masuk' : 'Kas keluar'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF222222),
                  ),
                ),
                Text(
                  time,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFAAAAAA),
                  ),
                ),
              ],
            ),
          ),
          Text(
            (mv.isIn ? '+' : '−') + CurrencyFormatter.format(mv.amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseReportModal extends StatefulWidget {
  final ShiftCloseReport report;
  const _CloseReportModal({required this.report});

  @override
  State<_CloseReportModal> createState() => _CloseReportModalState();
}

class _CloseReportModalState extends State<_CloseReportModal> {
  bool _printing = false;
  bool _printSuccess = false;
  bool _printToPrinter = true;
  bool _includeProducts = true;
  String? _printMessage;

  Future<void> _print() async {
    if (_printing) return;
    if (!_printToPrinter) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _printing = true;
      _printSuccess = false;
      _printMessage = 'Mengirim laporan ke printer struk...';
    });
    try {
      final outcome = await printShiftCloseReport(
        widget.report,
        includeProducts: _includeProducts,
      );
      if (!mounted) return;
      setState(() {
        _printing = false;
        _printSuccess = outcome == PrintOutcome.printed;
        _printMessage = switch (outcome) {
          PrintOutcome.printed =>
            _includeProducts
                ? 'Laporan dan produk terjual berhasil dicetak.'
                : 'Laporan berhasil dicetak tanpa produk terjual.',
          PrintOutcome.skipped =>
            'Printer struk belum dipilih. Atur printer lalu cetak ulang.',
          PrintOutcome.failed =>
            'Laporan belum berhasil dicetak. Periksa koneksi printer.',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _printing = false;
        _printMessage =
            'Laporan belum berhasil dicetak. Periksa koneksi printer.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final date = DateFormat('dd MMM yyyy, HH:mm', 'id_ID');
    return _panel(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: _SC.dark,
              padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
              child: Row(
                children: [
                  const Icon(
                    Icons.receipt_long_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Laporan Tutup Kasir',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (report.isProvisional) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFDBA74)),
                        ),
                        child: const Text(
                          'Laporan sementara offline. Angka final dihitung '
                          'server setelah seluruh transaksi tersinkron. Kasir '
                          'baru belum dapat dibuka sampai sinkronisasi selesai.',
                          style: TextStyle(
                            color: Color(0xFF9A3412),
                            fontSize: 12,
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(
                      report.outlet.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${report.cashierName}\n'
                      '${date.format(report.openedAt.toLocal())} – '
                      '${date.format(report.closedAt.toLocal())}',
                      style: const TextStyle(
                        color: _SC.ter,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _moneyBox([
                      _moneyRow('Modal awal', report.openingCash),
                      _moneyRow('Penerimaan tunai', report.cashReceived),
                      _moneyRow('Penerimaan nontunai', report.nonCashReceived),
                      if (report.cashIn != 0)
                        _moneyRow('Kas masuk', report.cashIn),
                      if (report.cashOut != 0)
                        _moneyRow(
                          'Pengeluaran kas',
                          -report.cashOut,
                          color: _SC.red,
                        ),
                      _moneyRow(
                        'Total penjualan',
                        report.totalReceipts,
                        bold: true,
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _moneyBox([
                      _moneyRow('Saldo seharusnya', report.expectedCash),
                      _moneyRow('Kas fisik', report.closingCash),
                      _moneyRow(
                        'Selisih kas',
                        report.cashDifference,
                        bold: true,
                        color: report.cashDifference == 0
                            ? _SC.ink
                            : report.cashDifference > 0
                            ? _SC.green
                            : _SC.red,
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _sectionTitle('RINGKASAN TRANSAKSI'),
                    _countRow(
                      'Transaksi selesai',
                      report.completedTransactions,
                    ),
                    _countRow('Belum terbayar', report.unpaidTransactions),
                    if (report.voidItemQuantity > 0)
                      _countRow('Item di-void', report.voidItemQuantity),
                    if (report.expenses.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _sectionTitle('PENGELUARAN KASIR'),
                      ...report.expenses.map(_expenseRow),
                      const Divider(height: 18),
                      _moneyRow(
                        'Total pengeluaran',
                        report.expenses.fold(
                          0,
                          (sum, item) => sum + item.amount,
                        ),
                        bold: true,
                        color: _SC.red,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _sectionTitle('PRODUK TERJUAL'),
                    if (report.products.isEmpty)
                      const Text(
                        'Tidak ada produk terjual.',
                        style: TextStyle(color: _SC.ter, fontSize: 13),
                      )
                    else
                      ...report.products.map(
                        (product) => _countRow(product.name, product.quantity),
                      ),
                    const Divider(height: 22),
                    _countRow(
                      'Total produk',
                      report.productQuantity,
                      bold: true,
                    ),
                    const SizedBox(height: 18),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAFAFA),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _SC.border),
                      ),
                      child: Column(
                        children: [
                          CheckboxListTile(
                            key: const Key('shift-close-print-toggle'),
                            value: _printToPrinter,
                            onChanged: _printing
                                ? null
                                : (value) => setState(() {
                                    _printToPrinter = value ?? false;
                                  }),
                            activeColor: _SC.green,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            title: const Text(
                              'Cetak laporan ke printer',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          CheckboxListTile(
                            key: const Key('shift-close-products-toggle'),
                            value: _printToPrinter && _includeProducts,
                            onChanged: !_printToPrinter || _printing
                                ? null
                                : (value) => setState(() {
                                    _includeProducts = value ?? false;
                                  }),
                            activeColor: _SC.green,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            title: const Text(
                              'Cetak produk terjual',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text(
                              'Matikan untuk mencetak ringkasan kasir saja.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_printMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _printSuccess ? _SC.greenBg : _SC.redBg,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          _printMessage!,
                          style: TextStyle(
                            fontSize: 13,
                            color: _printSuccess ? _SC.green : _SC.red,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Tutup'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _printing ? null : _print,
                      style: FilledButton.styleFrom(backgroundColor: _SC.ink),
                      icon: _printing
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              _printToPrinter
                                  ? Icons.print_outlined
                                  : Icons.check_circle_outline,
                              size: 18,
                            ),
                      label: Text(
                        _printing
                            ? 'Mencetak...'
                            : _printToPrinter
                            ? 'Cetak Laporan'
                            : 'Selesai Tanpa Cetak',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: _SC.ter,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _moneyBox(List<Widget> rows) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFFAFAFA),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _SC.border),
    ),
    child: Column(children: rows),
  );

  Widget _moneyRow(
    String label,
    double value, {
    bool bold = false,
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: color ?? _SC.sec,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          CurrencyFormatter.format(value),
          style: TextStyle(
            fontSize: 13,
            color: color ?? _SC.ink,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _countRow(String label, int value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: _SC.sec,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _expenseRow(ShiftExpenseSummary expense) {
    const labels = <String, String>{
      'bahan_baku': 'Bahan Baku',
      'operasional': 'Operasional',
      'gaji': 'Gaji',
      'peralatan': 'Peralatan',
      'marketing': 'Pemasaran',
      'lain_lain': 'Lain-lain',
    };
    final time = DateFormat(
      'dd MMM, HH:mm',
      'id_ID',
    ).format(expense.createdAt.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  expense.description,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _SC.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${labels[expense.category] ?? expense.category} · $time',
                  style: const TextStyle(fontSize: 11, color: _SC.ter),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            CurrencyFormatter.format(expense.amount),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _SC.red,
            ),
          ),
        ],
      ),
    );
  }
}

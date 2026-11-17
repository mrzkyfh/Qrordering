import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../core/utils/thousands_formatter.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../../../features/pos/data/datasources/pos_datasource.dart';
import '../../../../features/pos/data/datasources/shift_datasource.dart';
import '../../../../features/pos/presentation/bloc/shift_bloc.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/sync_service.dart';

// ── Shell ─────────────────────────────────────────────────────────────────────
class KasirShell extends StatelessWidget {
  final Widget child;
  const KasirShell({super.key, required this.child});

  static final GlobalKey<ScaffoldState> scaffoldKey =
      GlobalKey<ScaffoldState>();

  static void openMenu() => scaffoldKey.currentState?.openDrawer();

  // Waktu tekan back terakhir di POS home — untuk konfirmasi "tekan sekali lagi
  // untuk keluar" agar aplikasi tidak tertutup tak sengaja saat berjualan.
  static DateTime? _lastBackAt;

  @override
  Widget build(BuildContext context) {
    // Kelola tombol back (sistem & gestur) secara manual: halaman di dalam shell
    // dijangkau via context.go() (mengganti stack) sehingga tak ada yang bisa
    // di-pop → tanpa penanganan ini, back akan langsung menutup aplikasi.
    // - Sub-halaman (Order, Penjualan, Laporan, dll) → kembali ke POS home.
    // - POS home → minta konfirmasi tekan 2× sebelum keluar.
    // Halaman detail (Pembayaran, Meja, Printer) memakai push → back di sana
    // sudah otomatis pop ke halaman sebelumnya, tidak lewat sini.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Drawer terbuka → tutup drawer dulu (jangan navigasi/keluar).
        if (scaffoldKey.currentState?.isDrawerOpen ?? false) {
          scaffoldKey.currentState?.closeDrawer();
          return;
        }
        final loc = GoRouterState.of(context).uri.path;
        if (loc != '/kasir') {
          context.go('/kasir');
          return;
        }
        final now = DateTime.now();
        if (_lastBackAt == null ||
            now.difference(_lastBackAt!) > const Duration(seconds: 2)) {
          _lastBackAt = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tekan sekali lagi untuk keluar'),
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: AppColors.canvas,
        drawer: const _KasirDrawer(),
        body: child,
      ),
    );
  }
}

// ── Drawer (stateful for expand/collapse) ─────────────────────────────────────
class _KasirDrawer extends StatefulWidget {
  const _KasirDrawer();

  @override
  State<_KasirDrawer> createState() => _KasirDrawerState();
}

class _KasirDrawerState extends State<_KasirDrawer> {
  bool _laporanOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final loc = GoRouterState.of(context).matchedLocation;
    if (loc.startsWith('/kasir/laporan') && !_laporanOpen) {
      _laporanOpen = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthBloc>().state;
    final profile = auth is AuthAuthenticated ? auth.profile : null;
    final name = profile?.fullName ?? 'Kasir';
    final role = profile?.role.value ?? '';
    final outlet = profile?.outletName;
    final loc = GoRouterState.of(context).matchedLocation;
    final hasActiveShift = context.watch<ShiftBloc>().state.activeShift != null;

    // Profil & Pengaturan untuk semua role (hub Pengaturan ala Majoo).
    final akunItems = <_NavItem>[
      const _NavItem(
        Icons.manage_accounts_outlined,
        'Profil',
        '/kasir/profile',
      ),
      const _NavItem(
        Icons.settings_outlined,
        'Pengaturan',
        '/kasir/pengaturan',
      ),
    ];

    return Drawer(
      backgroundColor: Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header profil ─────────────────────────────────────
            _DrawerHeader(name: name, role: role, outlet: outlet),
            Divider(height: 1, thickness: 1, color: AppColors.border),

            // ── Nav items ─────────────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _SectionLabel('MENU'),

                  _DrawerItem(
                    icon: Icons.point_of_sale_outlined,
                    label: 'Kasir',
                    selected: loc == '/kasir',
                    index: 0,
                    onTap: () => _go(context, '/kasir'),
                  ),
                  _DrawerItem(
                    icon: Icons.receipt_long_outlined,
                    label: 'Daftar Order',
                    selected: loc.startsWith('/kasir/orders'),
                    index: 1,
                    onTap: () => _go(context, '/kasir/orders'),
                  ),
                  _DrawerItem(
                    icon: Icons.bar_chart_rounded,
                    label: 'Penjualan',
                    selected: loc.startsWith('/kasir/penjualan'),
                    index: 2,
                    onTap: () => _go(context, '/kasir/penjualan'),
                  ),

                  // Laporan — expandable. Disembunyikan untuk role kasir.
                  if (role != 'kasir')
                    _LaporanItem(
                      expanded: _laporanOpen,
                      isActive: loc.startsWith('/kasir/laporan'),
                      index: 3,
                      onToggle: () =>
                          setState(() => _laporanOpen = !_laporanOpen),
                      onSubTap: (i) {
                        Navigator.pop(context);
                        context.go('/kasir/laporan', extra: i);
                      },
                    ),

                  // Laporan khusus kasir: hanya riwayat buka/tutup shift.
                  if (role == 'kasir')
                    _DrawerItem(
                      icon: Icons.assignment_outlined,
                      label: 'Laporan',
                      selected: loc.startsWith('/kasir/laporan-kas'),
                      index: 3,
                      onTap: () => _go(context, '/kasir/laporan-kas'),
                    ),

                  // Login tidak membuka shift. Menu ini menjadi satu-satunya
                  // pintu manual untuk buka/tutup kasir dari shell.
                  if (role == 'kasir')
                    _DrawerItem(
                      icon: Icons.lock_clock_outlined,
                      label: hasActiveShift ? 'Tutup Kasir' : 'Buka Kasir',
                      selected: loc.startsWith('/kasir/shift'),
                      index: 4,
                      onTap: () => _go(context, '/kasir/shift'),
                    ),

                  // Absensi (jam kerja) — semua role.
                  _DrawerItem(
                    icon: Icons.access_time_rounded,
                    label: 'Absensi',
                    selected: loc.startsWith('/kasir/absensi'),
                    index: 4,
                    onTap: () => _go(context, '/kasir/absensi'),
                  ),

                  const SizedBox(height: 8),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: AppColors.border.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 8),

                  _SectionLabel('LAINNYA'),
                  ...akunItems.asMap().entries.map((e) {
                    final item = e.value;
                    return _DrawerItem(
                      icon: item.icon,
                      label: item.label,
                      selected: loc.startsWith(item.route),
                      index: 5 + e.key,
                      onTap: () => _go(context, item.route),
                    );
                  }),
                  _DrawerItem(
                    icon: Icons.logout_rounded,
                    label: 'Keluar',
                    selected: false,
                    danger: true,
                    index: 5 + akunItems.length,
                    onTap: () {
                      Navigator.pop(context);
                      context.read<AuthBloc>().add(AuthLogoutRequested());
                    },
                  ),
                ],
              ),
            ),

            // ── Info kasir ────────────────────────────────────────
            _DrawerInfoCard(
              kasirName: name.isNotEmpty
                  ? name[0].toUpperCase() + name.substring(1)
                  : name,
              outletId: profile?.outletId ?? '',
              kasirId: profile?.id ?? '',
            ),

            // ── Footer versi ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Row(
                children: [
                  Text(
                    'Versi 1.0.4',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textDisabled,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.statusReady,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Up to date',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.statusReady,
                      fontWeight: FontWeight.w500,
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

  void _go(BuildContext context, String route) {
    Navigator.pop(context);
    context.go(route);
  }
}

// ── Data class ────────────────────────────────────────────────────────────────
class _NavItem {
  final IconData icon;
  final String label;
  final String route;
  const _NavItem(this.icon, this.label, this.route);
}

// ── Laporan expandable item ───────────────────────────────────────────────────
class _LaporanItem extends StatelessWidget {
  final bool expanded;
  final bool isActive;
  final int index;
  final VoidCallback onToggle;
  final void Function(int) onSubTap;

  static const _subs = <(IconData, String)>[
    (Icons.summarize_outlined, 'Ringkasan Penjualan'),
    (Icons.leaderboard_outlined, '10 Laporan Teratas'),
    (Icons.block_outlined, 'Void'),
    (Icons.badge_outlined, 'Kasir'),
    (Icons.account_balance_wallet_outlined, 'Kas Kasir'),
    (Icons.fastfood_outlined, 'Produk Terjual'),
    (Icons.payments_outlined, 'Jenis Bayar'),
    (Icons.receipt_long_outlined, 'Daftar Order'),
    (Icons.assignment_return_outlined, 'Refund'),
  ];

  const _LaporanItem({
    required this.expanded,
    required this.isActive,
    required this.index,
    required this.onToggle,
    required this.onSubTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
          children: [
            // Header row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
              child: Stack(
                children: [
                  Material(
                    color: isActive ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: onToggle,
                      splashColor: AppColors.primary.withValues(alpha: 0.08),
                      highlightColor: AppColors.primary.withValues(alpha: 0.05),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.assessment_outlined,
                              size: 20,
                              color: isActive
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Text(
                                'Laporan',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: isActive
                                      ? AppColors.primary
                                      : AppColors.textPrimary,
                                  letterSpacing: -0.1,
                                ),
                              ),
                            ),
                            AnimatedRotation(
                              turns: expanded ? 0.25 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: isActive
                                    ? AppColors.primary
                                    : AppColors.textDisabled,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isActive)
                    Positioned(
                      left: 0,
                      top: 6,
                      bottom: 6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Sub-items (animated expand)
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: expanded
                  ? Column(
                      children: _subs.asMap().entries.map((e) {
                        return _SubItem(
                          icon: e.value.$1,
                          label: e.value.$2,
                          onTap: () => onSubTap(e.key),
                        );
                      }).toList(),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        )
        .animate(delay: Duration(milliseconds: 60 + index * 35))
        .fadeIn(duration: 180.ms, curve: Curves.easeOut)
        .slideX(begin: -0.06, duration: 180.ms, curve: Curves.easeOut);
  }
}

// ── Sub item laporan ──────────────────────────────────────────────────────────
class _SubItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SubItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 26, right: 8, top: 1, bottom: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          splashColor: AppColors.primary.withValues(alpha: 0.06),
          highlightColor: AppColors.primary.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 15, color: AppColors.textDisabled),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Header profil ─────────────────────────────────────────────────────────────
class _DrawerHeader extends StatelessWidget {
  final String name;
  final String role;
  final String? outlet;

  const _DrawerHeader({required this.name, required this.role, this.outlet});

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isNotEmpty
        ? name.trim().split(' ').take(2).map((w) => w[0]).join().toUpperCase()
        : '?';

    return Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, AppColors.primaryDark],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        if (role.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              role.toUpperCase(),
                              style: const TextStyle(
                                color: AppColors.slate600,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.statusReady,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Online',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.statusReady,
                    ),
                  ),
                  if (outlet != null) ...[
                    Text(
                      '  ·  ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textDisabled,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        outlet!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        )
        .animate()
        .fadeIn(duration: 250.ms, curve: Curves.easeOut)
        .slideY(begin: -0.05, duration: 250.ms, curve: Curves.easeOut);
  }
}

// ── Section label ─────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: AppColors.textSecondary.withValues(alpha: 0.45),
          letterSpacing: 1.3,
        ),
      ),
    );
  }
}

// ── Drawer item ───────────────────────────────────────────────────────────────
class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool danger;
  final int index;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.index,
    this.selected = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = danger
        ? AppColors.error
        : (selected ? AppColors.primary : AppColors.textSecondary);
    final labelColor = danger
        ? AppColors.error
        : (selected ? AppColors.primary : AppColors.textPrimary);

    return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
          child: Stack(
            children: [
              Material(
                color: selected ? AppColors.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onTap,
                  splashColor: (danger ? AppColors.error : AppColors.primary)
                      .withValues(alpha: 0.08),
                  highlightColor: (danger ? AppColors.error : AppColors.primary)
                      .withValues(alpha: 0.05),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 20, color: fg),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: labelColor,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  left: 0,
                  top: 6,
                  bottom: 6,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        )
        .animate(delay: Duration(milliseconds: 60 + index * 35))
        .fadeIn(duration: 180.ms, curve: Curves.easeOut)
        .slideX(begin: -0.06, duration: 180.ms, curve: Curves.easeOut);
  }
}

// ── Info card bawah ───────────────────────────────────────────────────────────
class _DrawerInfoCard extends StatefulWidget {
  final String kasirName;
  final String outletId;
  final String kasirId;
  const _DrawerInfoCard({
    required this.kasirName,
    required this.outletId,
    required this.kasirId,
  });

  @override
  State<_DrawerInfoCard> createState() => _DrawerInfoCardState();
}

class _DrawerInfoCardState extends State<_DrawerInfoCard> {
  String _openingCash = '...';

  @override
  void initState() {
    super.initState();
    _loadCash();
  }

  Future<void> _loadCash() async {
    if (widget.outletId.isEmpty || widget.kasirId.isEmpty) {
      if (mounted) setState(() => _openingCash = 'Rp -');
      return;
    }
    try {
      final ds = ShiftDatasource();
      final shift = await ds.fetchActiveShift(widget.outletId, widget.kasirId);
      if (shift == null) {
        if (mounted) setState(() => _openingCash = 'Belum buka');
        return;
      }
      // Kasir tidak membaca rincian Kas Masuk/Keluar. Drawer cukup menampilkan
      // modal awal yang memang berasal dari shift miliknya.
      if (mounted) {
        setState(
          () => _openingCash = CurrencyFormatter.format(shift.openingCash),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _openingCash = 'Rp -');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: _InfoCell(label: 'Kasir Aktif', value: widget.kasirName),
              ),
              Container(
                width: 1,
                height: 36,
                color: AppColors.border.withValues(alpha: 0.6),
              ),
              Expanded(
                child: _InfoCell(
                  label: 'Modal Awal',
                  value: _openingCash,
                  align: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(duration: 300.ms, delay: 300.ms, curve: Curves.easeOut);
  }
}

class _InfoCell extends StatelessWidget {
  final String label;
  final String value;
  final TextAlign align;
  const _InfoCell({
    required this.label,
    required this.value,
    this.align = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    final isRight = align == TextAlign.right;
    return Padding(
      padding: EdgeInsets.only(left: isRight ? 14 : 0, right: isRight ? 0 : 14),
      child: Column(
        crossAxisAlignment: isRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Host sesi kasir ──────────────────────────────────────────────────────────
// Login hanya memberi akses melihat aplikasi dan TIDAK membuka/memaksa shift.
// Shift dibuka manual dari menu Buka Kasir. Pembayaran tetap memiliki guard
// tersendiri yang mensyaratkan shift milik kasir aktif.
class KasirSessionHost extends StatefulWidget {
  final Widget child;
  const KasirSessionHost({super.key, required this.child});
  @override
  State<KasirSessionHost> createState() => _KasirSessionHostState();
}

class _KasirSessionHostState extends State<KasirSessionHost> {
  bool _promptShown = false;

  @override
  void initState() {
    super.initState();
    SyncService.instance.lastPaidOrderSynced.addListener(_onOrderSynced);
  }

  @override
  void dispose() {
    SyncService.instance.lastPaidOrderSynced.removeListener(_onOrderSynced);
    super.dispose();
  }

  /// Alert stok menipis akibat order yang baru tersinkron.
  ///
  /// Dulu dijalankan tepat setelah bayar, tapi sejak struk dicetak sebelum
  /// sinkron, order_id belum ada di server pada saat itu. Dipasang di shell
  /// (bukan halaman bayar) karena kasir sudah kembali ke layar POS saat order
  /// benar-benar sampai — halaman bayar-nya sudah tidak ada.
  Future<void> _onOrderSynced() async {
    final orderId = SyncService.instance.lastPaidOrderSynced.value;
    if (orderId == null) return;
    final lowStock = await PosDatasource().lowStockAfterOrder(orderId);
    if (!mounted || lowStock.isEmpty) return;
    AppToast.error(
      context,
      'Stok menipis: ${lowStock.take(3).join(', ')}'
      '${lowStock.length > 3 ? ', +${lowStock.length - 3} lainnya' : ''}',
      title: 'Segera restock',
    );
  }

  Future<void> _showOpenKasirPrompt(String outletId, String kasirId) async {
    final cashController = TextEditingController(text: '0');
    var submitting = false;
    var activeConflict = false;
    String? error;

    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          icon: const Icon(
            Icons.point_of_sale_outlined,
            color: AppColors.primary,
            size: 32,
          ),
          title: const Text('Buka Kasir?'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Kasir belum aktif. Buka sekarang untuk menerima pembayaran, atau pilih Nanti Saja jika hanya ingin mengecek aplikasi.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Kas Awal (Modal)',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                TextField(
                  controller: cashController,
                  enabled: !submitting,
                  keyboardType: TextInputType.number,
                  inputFormatters: [ThousandsInputFormatter()],
                  decoration: const InputDecoration(
                    prefixText: 'Rp ',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error!,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (activeConflict)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  context.go('/kasir/shift');
                },
                child: const Text('Lihat Sesi Aktif'),
              ),
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('Nanti Saja'),
            ),
            FilledButton(
              onPressed: submitting || activeConflict
                  ? null
                  : () async {
                      setDialogState(() {
                        submitting = true;
                        error = null;
                      });
                      try {
                        await context.read<ShiftBloc>().datasource.openShift(
                          outletId,
                          kasirId,
                          parseThousands(cashController.text),
                        );
                        if (!dialogContext.mounted) return;
                        Navigator.pop(dialogContext);
                        if (mounted) {
                          context.read<ShiftBloc>().add(
                            ShiftLoadRequested(outletId, kasirId),
                          );
                          AppToast.success(context, 'Kasir berhasil dibuka.');
                        }
                      } on ActiveShiftExistsException catch (exception) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          submitting = false;
                          activeConflict = true;
                          error = exception.message;
                        });
                        if (mounted) {
                          context.read<ShiftBloc>().add(
                            ShiftLoadRequested(outletId, kasirId),
                          );
                        }
                      } catch (exception) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          submitting = false;
                          error = humanizeError(
                            exception,
                            fallback: 'Gagal membuka kasir.',
                          );
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Buka Kasir'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    // The pop result precedes the exit animation; the TextField still needs
    // its controller until the dialog's overlay entries have been removed.
    await route.completed;
    cashController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final shiftState = context.watch<ShiftBloc>().state;
    final isKasir =
        auth is AuthAuthenticated && auth.profile.role == UserRole.kasir;
    final shiftResolved =
        auth is AuthAuthenticated &&
        shiftState.outletId == auth.profile.outletId &&
        shiftState.kasirId == auth.profile.id &&
        !shiftState.loading;
    final needsShift =
        isKasir &&
        shiftResolved &&
        shiftState.error == null &&
        shiftState.activeShift == null;

    if (needsShift && !_promptShown) {
      _promptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final latest = context.read<ShiftBloc>().state;
        if (latest.loading ||
            latest.error != null ||
            latest.activeShift != null ||
            latest.outletId != shiftState.outletId ||
            latest.kasirId != shiftState.kasirId) {
          _promptShown = false;
          return;
        }
        await _showOpenKasirPrompt(shiftState.outletId, shiftState.kasirId);
      });
    }

    final location = GoRouterState.of(context).matchedLocation;
    if (isKasir &&
        location == '/kasir' &&
        (!shiftResolved || shiftState.activeShift == null)) {
      return _KasirLockedView(
        loading: !shiftResolved,
        error: shiftState.error,
        onRetry: () => context.read<ShiftBloc>().add(
          ShiftLoadRequested(auth.profile.outletId ?? '', auth.profile.id),
        ),
      );
    }
    return widget.child;
  }
}

class _KasirLockedView extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  const _KasirLockedView({required this.loading, this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.canvas,
      child: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: KasirShell.openMenu,
                  icon: const Icon(Icons.menu),
                  tooltip: 'Buka menu',
                ),
                const SizedBox(width: 4),
                const Text(
                  'Kasir',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: loading
                        ? const Center(child: CircularProgressIndicator())
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: const BoxDecoration(
                                  color: AppColors.primarySubtle,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.lock_outline,
                                  color: AppColors.primary,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                error == null
                                    ? 'Kasir Belum Dibuka'
                                    : 'Status Kasir Belum Terverifikasi',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                error ??
                                    'Buka kasir terlebih dahulu untuk membuat dan menerima pembayaran transaksi.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: error == null
                                      ? () => context.go('/kasir/shift')
                                      : onRetry,
                                  icon: const Icon(Icons.point_of_sale),
                                  label: Text(
                                    error == null ? 'Buka Kasir' : 'Coba Lagi',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Menu lain tetap dapat dilihat melalui tombol menu.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textDisabled,
                                  fontSize: 11,
                                ),
                              ),
                            ],
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

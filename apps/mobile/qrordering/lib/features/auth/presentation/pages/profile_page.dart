import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../bloc/auth_bloc.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/shift.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../features/orders/data/datasources/orders_datasource.dart';
import '../../../../features/pos/data/datasources/shift_datasource.dart';
import '../../../../features/pos/presentation/pages/kasir_shell.dart';
import '../../../../features/settings/presentation/pages/settings_hub_page.dart';

// Palet style "Minimal Full White"
const _kRed = Color(0xFFE24B4A);
const _kRedDark = Color(0xFFB03030);
const _kBorder = Color(0xFFEFEFEF);
const _kCanvas = Color(0xFFF5F5F5);
const _kInk = Color(0xFF111111);
const _kMuted = Color(0xFF999999);

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Shift? _shift;
  int _totalOrders = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return;
    final outletId = auth.profile.outletId ?? '';
    if (outletId.isEmpty) return;
    try {
      final results = await Future.wait([
        ShiftDatasource().fetchActiveShift(outletId, auth.profile.id),
        OrdersDatasource().fetchCompletedOrders(outletId),
      ]);
      if (!mounted) return;
      setState(() {
        _shift = results[0] as Shift?;
        _totalOrders = (results[1] as List).length;
      });
    } catch (_) {
      // diam — kolom kiri tampil "-" bila gagal
    }
  }

  String get _email {
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    // Email sintetis akun staff/clock-in tidak relevan ditampilkan.
    return email.endsWith('@pos.local') ? '-' : email;
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return const SizedBox();
    final profile = authState.profile;

    final initial = profile.fullName.isNotEmpty
        ? profile.fullName[0].toUpperCase()
        : '?';
    final loginTime = profile.lastLoginAt != null
        ? _hhmm(profile.lastLoginAt!)
        : '-';
    // Pengaturan Perangkat/Printer tersedia untuk semua role staf
    // (owner/admin/manajer/kasir) — tiap perangkat/tablet perlu atur printernya.
    final canPrinter = profile.role == UserRole.owner ||
        profile.role == UserRole.admin ||
        profile.role == UserRole.manajer ||
        profile.role == UserRole.kasir;

    return Scaffold(
      backgroundColor: _kCanvas,
      body: SafeArea(
        child: Column(
          children: [
            // ── Topbar ────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                    bottom: BorderSide(color: _kBorder, width: 0.5)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu, size: 22, color: _kInk),
                    onPressed: KasirShell.openMenu,
                  ),
                  const Text('Profil',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: _kInk)),
                ],
              ),
            ),
            // ── Body ──────────────────────────────────────────────
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 200,
                    child: _LeftColumn(
                      initial: initial,
                      name: profile.fullName,
                      role: profile.role.value,
                      totalOrders: _totalOrders,
                      shiftLabel: _shift != null
                          ? 'Sejak ${_hhmm(_shift!.startTime)}'
                          : '-',
                      loginTime: loginTime,
                      onLogout: () => _confirmLogout(context),
                    ),
                  ),
                  Expanded(
                    child: _RightColumn(
                      email: _email,
                      phone: profile.phone ?? '',
                      lastLogin: profile.lastLoginAt,
                      canPrinter: canPrinter,
                      onPrinter: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SettingsHubPage())),
                      onChangePin: () => _showChangePinDialog(context, profile.id),
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

  static String _hhmm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Keluar'),
        content: const Text('Yakin ingin keluar dari akun ini?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Batal')),
          FilledButton(
            onPressed: () => context.read<AuthBloc>().add(AuthLogoutRequested()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
  }

  void _showChangePinDialog(BuildContext context, String selfId) {
    showDialog(
      context: context,
      builder: (_) => _ChangePinDialog(selfId: selfId),
    );
  }
}

// ── Dialog ganti PIN sendiri ─────────────────────────────────────────────────
// Self-PIN: server set_staff_pin selalu mengizinkan ubah PIN diri sendiri.
class _ChangePinDialog extends StatefulWidget {
  final String selfId;
  const _ChangePinDialog({required this.selfId});

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pinCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    if (!RegExp(r'^[0-9]{4}$').hasMatch(pin)) {
      setState(() => _error = 'PIN harus tepat 4 digit angka');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'Konfirmasi PIN tidak cocok');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('set_staff_pin', params: {
        'p_target': widget.selfId,
        'p_pin': pin,
      });
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN berhasil diganti')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Gagal mengganti PIN, coba lagi';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ganti PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: 'PIN baru (4 digit)',
              counterText: '',
            ),
          ),
          TextField(
            controller: _confirmCtrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: 'Konfirmasi PIN',
              counterText: '',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Simpan'),
        ),
      ],
    );
  }
}

// ── Kolom kiri ──────────────────────────────────────────────────────────────
class _LeftColumn extends StatelessWidget {
  final String initial;
  final String name;
  final String role;
  final int totalOrders;
  final String shiftLabel;
  final String loginTime;
  final VoidCallback onLogout;

  const _LeftColumn({
    required this.initial,
    required this.name,
    required this.role,
    required this.totalOrders,
    required this.shiftLabel,
    required this.loginTime,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: _kBorder, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [_kRed, _kRedDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Text(initial,
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ),
          const SizedBox(height: 10),
          // Nama
          Text(name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _kInk)),
          const SizedBox(height: 5),
          // Role badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _kCanvas,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(role.toUpperCase(),
                style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF555555),
                    letterSpacing: 0.5)),
          ),
          const SizedBox(height: 6),
          // Status aktif
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                    color: Color(0xFF4ADE80), shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              const Text('Aktif sekarang',
                  style: TextStyle(fontSize: 10, color: Color(0xFF888888))),
            ],
          ),
          // Divider
          Container(
            height: 0.5,
            color: const Color(0xFFF0F0F0),
            margin: const EdgeInsets.symmetric(vertical: 16),
          ),
          // Info list
          _sideRow('Total Order', '$totalOrders'),
          const SizedBox(height: 8),
          _sideRow('Shift', shiftLabel),
          const SizedBox(height: 8),
          _sideRow('Login', loginTime),

          const Spacer(),
          // Tombol Keluar
          SizedBox(
            width: double.infinity,
            height: 34,
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout, size: 14, color: _kRed),
              label: const Text('Keluar',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: _kRed)),
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                side: const BorderSide(color: _kRed, width: 1.5),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sideRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: _kMuted)),
          Text(value,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w500, color: _kInk)),
        ],
      );
}

// ── Kolom kanan ─────────────────────────────────────────────────────────────
class _RightColumn extends StatelessWidget {
  final String email;
  final String phone;
  final DateTime? lastLogin;
  final bool canPrinter;
  final VoidCallback onPrinter;
  final VoidCallback onChangePin;

  const _RightColumn({
    required this.email,
    required this.phone,
    required this.lastLogin,
    required this.canPrinter,
    required this.onPrinter,
    required this.onChangePin,
  });

  @override
  Widget build(BuildContext context) {
    final loginStr = lastLogin != null
        ? '${lastLogin!.day}/${lastLogin!.month}/${lastLogin!.year} · '
            '${lastLogin!.hour.toString().padLeft(2, '0')}:'
            '${lastLogin!.minute.toString().padLeft(2, '0')}'
        : '-';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Informasi Akun ──────────────────────────────────────
          const _SectionLabel('Informasi Akun'),
          _InfoCard(rows: [
            _InfoRow(
              iconBg: const Color(0xFFFFECEC),
              iconColor: _kRedDark,
              icon: Icons.email_outlined,
              topLabel: 'Email',
              value: email,
              trailing: _arrow,
            ),
            _InfoRow(
              iconBg: const Color(0xFFEAF3DE),
              iconColor: const Color(0xFF27500A),
              icon: Icons.phone_outlined,
              topLabel: 'Telepon',
              value: phone,
              trailing: _arrow,
            ),
            _InfoRow(
              iconBg: const Color(0xFFFEF3C7),
              iconColor: const Color(0xFF92400E),
              icon: Icons.access_time,
              topLabel: 'Login Terakhir',
              value: loginStr,
              forceFilled: true,
            ),
          ]),
          const SizedBox(height: 10),
          // ── Keamanan & Perangkat ────────────────────────────────
          const _SectionLabel('Keamanan & Perangkat'),
          _InfoCard(rows: [
            _InfoRow(
              iconBg: const Color(0xFFFFECEC),
              iconColor: _kRedDark,
              icon: Icons.lock_outline,
              title: 'PIN Keamanan',
              subtitle: 'Ketuk untuk ganti PIN Anda',
              trailing: _arrow,
              onTap: onChangePin,
            ),
            if (canPrinter)
              _InfoRow(
                iconBg: const Color(0xFFEAF3DE),
                iconColor: const Color(0xFF27500A),
                icon: Icons.print_outlined,
                title: 'Pengaturan',
                subtitle: 'Perangkat, struk & biaya, PIN, dll',
                trailing: _arrow,
                onTap: onPrinter,
              ),
          ]),
        ],
      ),
    );
  }

  static const Widget _arrow =
      Icon(Icons.chevron_right, size: 14, color: Color(0xFFD0D0D0));
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: Color(0xFFBBBBBB))),
      );
}

class _InfoCard extends StatelessWidget {
  final List<Widget> rows;
  const _InfoCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              decoration: BoxDecoration(
                border: i < rows.length - 1
                    ? const Border(
                        bottom:
                            BorderSide(color: Color(0xFFF5F5F5), width: 0.5))
                    : null,
              ),
              child: rows[i],
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final Color iconBg;
  final Color iconColor;
  final IconData icon;
  final String? topLabel; // mode a: label di atas nilai
  final String? value; // nilai untuk mode a
  final String? title; // mode b: judul tebal
  final String? subtitle; // mode b: subjudul
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool forceFilled; // nilai tak pernah kosong (mis. Login)

  const _InfoRow({
    required this.iconBg,
    required this.iconColor,
    required this.icon,
    this.topLabel,
    this.value,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.forceFilled = false,
  });

  @override
  Widget build(BuildContext context) {
    final empty = !forceFilled &&
        topLabel != null &&
        (value == null || value!.trim().isEmpty || value == '-');

    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 14, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (topLabel != null) ...[
                  Text(topLabel!,
                      style: const TextStyle(fontSize: 10, color: _kMuted)),
                  const SizedBox(height: 1),
                  empty
                      ? const Text('Belum diisi',
                          style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: Color(0xFFCCCCCC)))
                      : Text(value ?? '-',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: _kInk)),
                ] else ...[
                  Text(title ?? '',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _kInk)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(subtitle!,
                        style: const TextStyle(fontSize: 10, color: _kMuted)),
                  ],
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap == null) return body;
    return InkWell(onTap: onTap, child: body);
  }
}


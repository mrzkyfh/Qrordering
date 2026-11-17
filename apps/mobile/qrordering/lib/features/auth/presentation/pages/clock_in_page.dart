import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../bloc/auth_bloc.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../shared/services/supabase_service.dart';

// ── Palet (spec desain) ──────────────────────────────────────────────────────
const _kBg = Color(0xFFF5F5F5);
const _kRed = Color(0xFFE24B4A);
const _kInk = Color(0xFF111111);
const _kBorder = Color(0xFFE8E8E8);
const _kMuted = Color(0xFF999999);
const _kLabel = Color(0xFFBBBBBB);

const _avatarGradients = [
  [Color(0xFFE24B4A), Color(0xFFB03030)],
  [Color(0xFF2563EB), Color(0xFF1D4ED8)],
  [Color(0xFF7C3AED), Color(0xFF6D28D9)],
  [Color(0xFF1D9E75), Color(0xFF166534)],
];

@visibleForTesting
String clockInErrorMessage(Object? error) {
  final raw = error?.toString().replaceFirst('Exception: ', '').trim() ?? '';
  final lower = raw.toLowerCase();
  if (lower.contains('pin salah') ||
      lower.contains('pin tidak valid') ||
      lower.contains('invalid pin')) {
    return 'PIN salah, coba lagi';
  }
  if (lower.contains('pin terkunci')) {
    return raw;
  }
  return humanizeError(
    error,
    fallback:
        'PIN sudah diterima, tetapi proses masuk belum selesai. Coba lagi.',
  );
}

/// Halaman Clock-In / Login Staff: pilih akun (dropdown) + PIN 4 digit.
/// Muncul setelah perangkat login akun cabang. Outlet dari akun perangkat.
class ClockInPage extends StatefulWidget {
  const ClockInPage({super.key});
  @override
  State<ClockInPage> createState() => _ClockInPageState();
}

class _ClockInPageState extends State<ClockInPage>
    with SingleTickerProviderStateMixin {
  static const _maxPin = 4;
  final _svc = SupabaseService();

  List<Map<String, dynamic>> _staff = const [];
  bool _loading = true;
  String? _loadError;
  String? _outletId;

  int? _selectedIndex;
  String _pin = '';
  bool _dropdownOpen = false;
  bool _isError = false;
  bool _submitting = false;
  String? _errorMsg;

  String _clockTime = '';
  Timer? _timer;

  late final AnimationController _shakeCtrl;

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _tick() {
    final t = DateFormat('EEE, dd MMM yyyy · HH:mm:ss').format(DateTime.now());
    if (mounted) setState(() => _clockTime = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shakeCtrl.dispose();
    super.dispose();
  }

  String? get _stateOutletId {
    final s = context.read<AuthBloc>().state;
    return s is AuthClockInRequired ? s.outletId : null;
  }

  String get _outletName {
    final s = context.read<AuthBloc>().state;
    return s is AuthClockInRequired ? (s.outletName ?? 'Outlet') : 'Outlet';
  }

  Future<void> _load() async {
    _outletId = _stateOutletId;
    if (_outletId == null || _outletId!.isEmpty) {
      setState(() {
        _loading = false;
        _loadError =
            'Outlet perangkat tidak diketahui. Login ulang akun cabang.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final staff = await _svc.listClockinStaff(_outletId!);
      if (!mounted) return;
      setState(() => _staff = staff);
    } catch (e) {
      if (mounted) setState(() => _loadError = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? get _selected =>
      _selectedIndex != null ? _staff[_selectedIndex!] : null;

  bool get _selectedHasPin => _selected?['has_pin'] == true;

  void _selectStaff(int index) {
    final s = _staff[index];
    if (s['has_pin'] != true) {
      AppToast.info(
        context,
        'Belum ada PIN. Atur dari owner-panel web → Manajemen Staff → Atur PIN.',
        title: 'Belum ada PIN',
      );
      return;
    }
    setState(() {
      _selectedIndex = index;
      _dropdownOpen = false;
      _pin = '';
      _isError = false;
      _submitting = false;
      _errorMsg = null;
    });
  }

  void _onKey(String key, bool verifying) {
    if (verifying || _submitting || _isError) return;
    setState(() {
      _errorMsg = null;
      _isError = false;
      if (key == '<') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < _maxPin) {
        _pin += key;
      }
    });
    if (_pin.length == _maxPin) _submit();
  }

  void _submit() {
    final s = _selected;
    if (_submitting || s == null || s['has_pin'] != true) return;
    setState(() => _submitting = true);
    context.read<AuthBloc>().add(
      AuthClockInRequested(
        outletId: _outletId!,
        staffId: s['id'] as String,
        pin: _pin,
      ),
    );
  }

  void _onError(String message) {
    setState(() {
      _isError = true;
      _submitting = false;
      _errorMsg = clockInErrorMessage(message);
    });
    _shakeCtrl.forward(from: 0);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _pin = '';
          _isError = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: BlocListener<AuthBloc, AuthState>(
          listenWhen: (prev, curr) => curr is AuthError,
          listener: (context, state) => _onError((state as AuthError).message),
          child: Column(
            children: [
              _topbar(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _loadError != null
                    ? _errorView()
                    : Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _card(),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Topbar ──────────────────────────────────────────────────────────────
  Widget _topbar() {
    final name = _outletName;
    final initials = name.trim().isNotEmpty
        ? name
              .trim()
              .substring(0, math.min(2, name.trim().length))
              .toUpperCase()
        : '??';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/images/logo.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _kRed,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      initials,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _kInk,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      _clockTime,
                      style: const TextStyle(fontSize: 10, color: _kMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Card utama ────────────────────────────────────────────────────────────
  Widget _card() {
    final width = math.min(300.0, MediaQuery.of(context).size.width - 48);
    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder, width: 0.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _dropdownLabel(),
          _dropdownTrigger(),
          _dropdownOptions(),
          // Bagian PIN
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _selectedHasPin ? 1 : 0,
              child: _selectedHasPin
                  ? _pinSection()
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdownLabel() => const Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Text(
        'AKUN',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: _kLabel,
          letterSpacing: 0.5,
        ),
      ),
    ),
  );

  Widget _dropdownTrigger() {
    final s = _selected;
    final selected = s != null;
    return GestureDetector(
      onTap: () => setState(() => _dropdownOpen = !_dropdownOpen),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF5F5) : const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _kRed : _kBorder, width: 1.5),
        ),
        child: Row(
          children: [
            _avatar(
              selected ? (s['full_name'] ?? '?') as String : '?',
              selected ? _selectedIndex! : 0,
              28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: selected
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (s['full_name'] ?? '-') as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _kInk,
                          ),
                        ),
                        Text(
                          '${_roleLabel((s['role'] ?? '') as String)} · $_outletName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: _kMuted),
                        ),
                      ],
                    )
                  : const Text(
                      'Pilih nama Anda',
                      style: TextStyle(fontSize: 12, color: _kMuted),
                    ),
            ),
            AnimatedRotation(
              turns: _dropdownOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: const Icon(
                Icons.keyboard_arrow_down,
                size: 16,
                color: _kLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdownOptions() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: !_dropdownOpen
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              constraints: const BoxConstraints(maxHeight: 200),
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
                itemBuilder: (_, i) => _optionRow(i),
              ),
            ),
    );
  }

  Widget _optionRow(int i) {
    final s = _staff[i];
    final name = (s['full_name'] ?? '-') as String;
    final role = (s['role'] ?? '') as String;
    final hasPin = s['has_pin'] == true;
    final isSelected = _selectedIndex == i;
    final isLast = i == _staff.length - 1;

    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFF5F5F5), width: 0.5),
              ),
      ),
      child: Row(
        children: [
          _avatar(name, i, 28),
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
                    color: isSelected ? _kRed : _kInk,
                    fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
                Text(
                  _roleLabel(role),
                  style: const TextStyle(fontSize: 9, color: _kMuted),
                ),
              ],
            ),
          ),
          if (isSelected)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.check, size: 14, color: _kRed),
            ),
          _pinBadge(hasPin),
        ],
      ),
    );

    return InkWell(
      onTap: () => _selectStaff(i),
      child: hasPin ? row : Opacity(opacity: 0.4, child: row),
    );
  }

  Widget _pinBadge(bool hasPin) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: hasPin ? const Color(0xFFEAF3DE) : const Color(0xFFF0F0F0),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      hasPin ? 'PIN ✓' : 'No PIN',
      style: TextStyle(
        fontSize: 9,
        color: hasPin ? const Color(0xFF27500A) : _kLabel,
      ),
    ),
  );

  Widget _avatar(String name, int index, double size) {
    final g = _avatarGradients[index % _avatarGradients.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: LinearGradient(
          colors: g,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  // ── PIN section ─────────────────────────────────────────────────────────
  Widget _pinSection() {
    final verifying =
        _submitting ||
        _isError ||
        context.watch<AuthBloc>().state is AuthLoading;
    return Column(
      children: [
        Container(
          height: 0.5,
          color: const Color(0xFFF0F0F0),
          margin: const EdgeInsets.symmetric(vertical: 14),
        ),
        const Text(
          'MASUKKAN PIN',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: _kLabel,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 18,
          child: verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _kRed,
                  ),
                )
              : _dots(),
        ),
        const SizedBox(height: 14),
        _numpad(verifying),
        if (_errorMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _errorMsg!,
              style: const TextStyle(fontSize: 11, color: _kRed),
            ),
          ),
      ],
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
        children: List.generate(_maxPin, (i) {
          final filled = i < _pin.length;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            width: 13,
            height: 13,
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

  Widget _numpad(bool verifying) {
    return _ClockInNumpad(onKey: (key) => _onKey(key, verifying));
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: _kMuted),
            const SizedBox(height: 12),
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _kMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Coba lagi')),
          ],
        ),
      ),
    );
  }

  static String _roleLabel(String role) => switch (role) {
    'owner' => 'Owner',
    'admin' => 'Admin',
    'manajer' => 'Manajer',
    'kasir' => 'Kasir',
    _ => role,
  };
}

@visibleForTesting
Widget buildClockInNumpadForTest({required ValueChanged<String> onKey}) =>
    _ClockInNumpad(onKey: onKey);

class _ClockInNumpad extends StatelessWidget {
  final ValueChanged<String> onKey;

  const _ClockInNumpad({required this.onKey});

  @override
  Widget build(BuildContext context) {
    Widget numBtn(String n) => _KeyButton(label: n, onTap: () => onKey(n));
    return Column(
      children: [
        _numRow([numBtn('1'), numBtn('2'), numBtn('3')]),
        const SizedBox(height: 6),
        _numRow([numBtn('4'), numBtn('5'), numBtn('6')]),
        const SizedBox(height: 6),
        _numRow([numBtn('7'), numBtn('8'), numBtn('9')]),
        const SizedBox(height: 6),
        _numRow([
          const SizedBox(),
          numBtn('0'),
          _KeyButton(label: '<', onTap: () => onKey('<')),
        ]),
      ],
    );
  }

  Widget _numRow(List<Widget> children) {
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      spaced.add(Expanded(child: children[i]));
      if (i < children.length - 1) spaced.add(const SizedBox(width: 6));
    }
    return Row(children: spaced);
  }
}

class _KeyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _KeyButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isBackspace = label == '<';
    return Material(
      color: isBackspace ? const Color(0xFFF0F0F0) : const Color(0xFFF8F8F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: _kRed.withValues(alpha: 0.1),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
          ),
          child: isBackspace
              ? const Icon(
                  Icons.backspace_outlined,
                  size: 18,
                  color: Color(0xFF666666),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: _kInk,
                  ),
                ),
        ),
      ),
    );
  }
}

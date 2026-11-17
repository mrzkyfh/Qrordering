import 'package:flutter/material.dart';

/// Design-kit Pengaturan — palet monokrom (hitam/putih/abu-abu) sesuai spec.
/// Dipakai bersama oleh hub Pengaturan + semua sub-halaman.
class SK {
  SK._();
  static const bg = Color(0xFFF5F5F5);
  static const card = Colors.white;
  static const border = Color(0xFFEBEBEB);
  static const borderLt = Color(0xFFF0F0F0);
  static const ink = Color(0xFF111111);
  static const muted = Color(0xFF999999);
  static const faint = Color(0xFFBBBBBB);
  static const iconBg = Color(0xFFF5F5F5);
  static const iconStroke = Color(0xFF555555);
  static const hover = Color(0xFFFAFAFA);
}

/// Toggle monokrom: track 44×26, thumb 20, off #e0e0e0 → on #111.
class AppToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => onChanged(!value) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 44,
        height: 26,
        decoration: BoxDecoration(
          color: !enabled
              ? const Color(0xFFE8E8E8)
              : value
              ? SK.ink
              : const Color(0xFFE0E0E0),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              left: value ? 21 : 3,
              top: 3,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scaffold sub-halaman dengan header 54px (chevron + judul + opsional Simpan),
/// animasi masuk translateX + fade.
class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback? onSave;
  final bool saving;
  final Widget? floatingActionButton;
  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.onSave,
    this.saving = false,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SK.bg,
      floatingActionButton: floatingActionButton,
      body: Column(
        children: [
          _Header(title: title, onSave: onSave, saving: saving),
          Expanded(
            child: _Entrance(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// FAB pill monokrom ("+ Tambah …") sesuai spec.
class SKFab extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const SKFab({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: SK.ink,
          borderRadius: BorderRadius.circular(50),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add, size: 18, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onSave;
  final bool saving;
  const _Header({required this.title, this.onSave, this.saving = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: SK.border)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(6),
            child: const SizedBox(
              width: 30,
              height: 30,
              child: Icon(Icons.chevron_left, size: 24, color: SK.ink),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: SK.ink,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (onSave != null)
            GestureDetector(
              onTap: saving ? null : onSave,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: saving ? SK.faint : SK.ink,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  saving ? 'Menyimpan…' : 'Simpan',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Entrance extends StatefulWidget {
  final Widget child;
  const _Entrance({required this.child});
  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.04, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut)),
        child: widget.child,
      ),
    );
  }
}

/// Label section ("OPERASIONAL", "TAMPILAN STRUK", dst.).
Widget skSectionLabel(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
  child: Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: SK.muted,
      letterSpacing: 0.8,
    ),
  ),
);

/// Card putih border tipis, rows di-clip.
Widget skCard(List<Widget> children) => Container(
  decoration: BoxDecoration(
    color: SK.card,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: SK.border),
  ),
  clipBehavior: Clip.antiAlias,
  child: Column(children: _withDividers(children)),
);

List<Widget> _withDividers(List<Widget> rows) {
  final out = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    out.add(rows[i]);
    if (i < rows.length - 1) {
      out.add(const Divider(height: 1, thickness: 1, color: SK.borderLt));
    }
  }
  return out;
}

/// Baris navigasi (hub): icon container + label + deskripsi + chevron.
class SKNavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String desc;
  final VoidCallback onTap;
  const SKNavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.desc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        hoverColor: SK.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SK.iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: SK.iconStroke),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: SK.ink,
                      ),
                    ),
                    if (desc.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          desc,
                          style: const TextStyle(fontSize: 12, color: SK.muted),
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: Color(0xFFCCCCCC),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Baris toggle: label (+ deskripsi opsional) + AppToggle di kanan.
class SKToggleRow extends StatelessWidget {
  final String label;
  final String? desc;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? trailingOverride; // mis. teks "Selalu aktif"
  final bool enabled;
  const SKToggleRow({
    super.key,
    required this.label,
    this.desc,
    required this.value,
    required this.onChanged,
    this.trailingOverride,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SK.ink,
                  ),
                ),
                if (desc != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      desc!,
                      style: const TextStyle(fontSize: 12, color: SK.muted),
                    ),
                  ),
              ],
            ),
          ),
          trailingOverride ??
              AppToggle(value: value, onChanged: onChanged, enabled: enabled),
        ],
      ),
    );
  }
}

/// Field borderless dengan label uppercase (form Info Outlet / Pajak / PIN).
class SKField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final int? maxLength;
  final double fontSize;
  final double letterSpacing;
  final bool enabled;
  const SKField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.obscure = false,
    this.maxLength,
    this.fontSize = 14,
    this.letterSpacing = 0,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: SK.muted,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            obscureText: obscure,
            maxLength: maxLength,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: SK.ink,
              letterSpacing: letterSpacing,
            ),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              filled: false,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: hint,
              hintStyle: TextStyle(
                color: SK.faint,
                fontWeight: FontWeight.w500,
                fontSize: fontSize,
                letterSpacing: letterSpacing,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

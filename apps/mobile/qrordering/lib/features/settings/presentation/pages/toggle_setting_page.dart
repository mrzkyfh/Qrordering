import 'package:flutter/material.dart';
import '../widgets/settings_kit.dart';

/// Halaman pengaturan satu switch (spec monokrom): card icon + label + status
/// + AppToggle, deskripsi di bawah. Dipakai untuk Order Online & Notifikasi Suara.
class ToggleSettingPage extends StatefulWidget {
  final String title;
  final String heading;
  final String description;
  final IconData icon;
  final bool initialValue;
  final Future<void> Function(bool) onChanged;

  const ToggleSettingPage({
    super.key,
    required this.title,
    required this.heading,
    required this.description,
    required this.icon,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<ToggleSettingPage> createState() => _ToggleSettingPageState();
}

class _ToggleSettingPageState extends State<ToggleSettingPage> {
  late bool _value = widget.initialValue;

  Future<void> _set(bool v) async {
    setState(() => _value = v);
    await widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: widget.title,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          skCard([
            Padding(
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
                    child: Icon(widget.icon, size: 17, color: SK.iconStroke),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.heading,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: SK.ink)),
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            _value ? 'Aktif' : 'Nonaktif',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: _value ? SK.ink : SK.faint),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AppToggle(value: _value, onChanged: _set),
                ],
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
            child: Text(
              widget.description,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFFAAAAAA), height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/settings_kit.dart';

/// Ganti PIN staf (sebelumnya dialog) — kini halaman penuh sesuai spec.
class PasswordPinPage extends StatefulWidget {
  final String selfId;
  const PasswordPinPage({super.key, required this.selfId});

  @override
  State<PasswordPinPage> createState() => _PasswordPinPageState();
}

class _PasswordPinPageState extends State<PasswordPinPage> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pin.text.trim();
    if (!RegExp(r'^[0-9]{4}$').hasMatch(pin)) {
      setState(() => _error = 'PIN harus tepat 4 digit angka');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = 'Konfirmasi PIN tidak cocok');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('set_staff_pin', params: {
        'p_target': widget.selfId,
        'p_pin': pin,
      });
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN berhasil diganti')));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Gagal mengganti PIN, coba lagi';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Password & PIN',
      onSave: _save,
      saving: _saving,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          skCard([
            SKField(
              label: 'PIN baru (4 digit)',
              controller: _pin,
              keyboardType: TextInputType.number,
              obscure: true,
              maxLength: 4,
              fontSize: 20,
              letterSpacing: 8,
              hint: '••••',
            ),
            SKField(
              label: 'Konfirmasi PIN',
              controller: _confirm,
              keyboardType: TextInputType.number,
              obscure: true,
              maxLength: 4,
              fontSize: 20,
              letterSpacing: 8,
              hint: '••••',
            ),
          ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(_error!,
                  style: const TextStyle(
                      color: Color(0xFFDD1111), fontSize: 12, fontWeight: FontWeight.w500)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 14, 4, 0),
            child: Text(
              'PIN digunakan untuk membuka akses kasir. Pastikan Anda mengingatnya.',
              style: TextStyle(fontSize: 12, color: Color(0xFFAAAAAA), height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

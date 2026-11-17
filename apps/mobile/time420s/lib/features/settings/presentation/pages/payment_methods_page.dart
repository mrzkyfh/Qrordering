import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/settings_kit.dart';

/// Pembayaran Non-Tunai — pilih metode pembayaran yang aktif.
/// Disimpan di outlets.settings.payment_methods (list). Akses: owner/admin.
class PaymentMethodsPage extends StatefulWidget {
  final String outletId;
  const PaymentMethodsPage({super.key, required this.outletId});
  @override
  State<PaymentMethodsPage> createState() => _PaymentMethodsPageState();
}

class _PaymentMethodsPageState extends State<PaymentMethodsPage> {
  // value -> label. 'cash' selalu aktif (tidak bisa dimatikan).
  static const _methods = <String, String>{
    'qris': 'QRIS',
    'debit': 'Kartu Debit',
    'credit': 'Kartu Kredit',
    'ewallet': 'E-Wallet',
    'transfer': 'Transfer Bank',
  };

  Map<String, dynamic> _s = {};
  late Set<String> _active;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _active = {};
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('outlets')
          .select('settings')
          .eq('id', widget.outletId)
          .single();
      _s = Map<String, dynamic>.from((row['settings'] as Map?) ?? {});
      final raw = _s['payment_methods'];
      if (raw is List) {
        _active = raw.map((e) => e.toString()).toSet();
      } else {
        // default: semua aktif
        _active = {'cash', ..._methods.keys};
      }
    } catch (_) {/* abaikan */}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // Hanya kunci milik halaman ini — lihat catatan di update_outlet_settings
    // (migration 113): menulis balik seluruh blob menimpa perubahan orang lain,
    // dan UPDATE langsung yang ditolak RLS dilaporkan sebagai "berhasil".
    final patch = <String, dynamic>{
      'payment_methods': ['cash', ..._active.where((m) => m != 'cash')],
    };
    try {
      final merged = await Supabase.instance.client.rpc(
        'update_outlet_settings',
        params: {'p_outlet_id': widget.outletId, 'p_patch': patch},
      );
      if (merged is Map) _s = Map<String, dynamic>.from(merged);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metode pembayaran tersimpan')));
    } catch (e) {
      if (!mounted) return;
      final denied = e is PostgrestException && e.code == '42501';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(denied
            ? 'Hanya owner/admin yang bisa mengubah metode pembayaran'
            : 'Gagal menyimpan — cek koneksi'),
        backgroundColor: const Color(0xFF991B1B)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Pembayaran Non-Tunai',
      onSave: _save,
      saving: _saving,
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: SK.ink))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                skCard([
                  const SKToggleRow(
                    label: 'Tunai',
                    value: true,
                    onChanged: _noop,
                    trailingOverride: Text('Selalu aktif',
                        style: TextStyle(fontSize: 12, color: SK.faint)),
                  ),
                  for (final e in _methods.entries)
                    SKToggleRow(
                      label: e.value,
                      value: _active.contains(e.key),
                      onChanged: (v) => setState(() {
                        if (v) {
                          _active.add(e.key);
                        } else {
                          _active.remove(e.key);
                        }
                      }),
                    ),
                ]),
              ],
            ),
    );
  }

  static void _noop(bool _) {}
}

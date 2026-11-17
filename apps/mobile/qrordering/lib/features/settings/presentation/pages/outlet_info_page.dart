import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/settings_kit.dart';

/// Info Outlet — lihat/edit nama, alamat, telepon, kota outlet.
/// Akses: owner/admin (ditegakkan RLS outlets_update).
class OutletInfoPage extends StatefulWidget {
  final String outletId;
  const OutletInfoPage({super.key, required this.outletId});
  @override
  State<OutletInfoPage> createState() => _OutletInfoPageState();
}

class _OutletInfoPageState extends State<OutletInfoPage> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('outlets')
          .select('name, address, phone, city')
          .eq('id', widget.outletId)
          .single();
      _name.text = (row['name'] as String?) ?? '';
      _address.text = (row['address'] as String?) ?? '';
      _phone.text = (row['phone'] as String?) ?? '';
      _city.text = (row['city'] as String?) ?? '';
    } catch (_) {/* abaikan */}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Nama outlet wajib diisi', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      // .select() WAJIB: UPDATE yang disaring RLS (mis. kasir, yang memang tak
      // berhak) cocok 0 baris dan dibalas SUKSES oleh PostgREST — tanpa cek ini
      // aplikasi melaporkan "tersimpan" padahal tak ada yang berubah.
      final rows = await Supabase.instance.client.from('outlets').update({
        'name': _name.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
        'city': _city.text.trim(),
      }).eq('id', widget.outletId).select('id');
      if (!mounted) return;
      if ((rows as List).isEmpty) {
        _snack('Hanya owner/admin yang bisa mengubah info outlet', error: true);
        return;
      }
      _snack('Info outlet tersimpan');
    } catch (e) {
      if (!mounted) return;
      _snack('Gagal menyimpan — cek koneksi', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: error ? const Color(0xFF991B1B) : const Color(0xFF111111),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Info Outlet',
      onSave: _save,
      saving: _saving,
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: SK.ink))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                skCard([
                  SKField(
                      label: 'Nama Outlet',
                      controller: _name,
                      hint: 'Masukkan nama outlet'),
                  SKField(
                      label: 'Alamat',
                      controller: _address,
                      hint: 'Masukkan alamat'),
                  SKField(
                      label: 'Telepon',
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      hint: 'Masukkan nomor telepon'),
                  SKField(
                      label: 'Kota', controller: _city, hint: 'Masukkan kota'),
                ]),
              ],
            ),
    );
  }
}

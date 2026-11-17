import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../../shared/models/enums.dart';
import '../widgets/settings_kit.dart';

/// Pengaturan Order Online bersifat outlet-wide, bukan preferensi perangkat.
/// Enforcement terakhir dilakukan database agar QR lama juga mengikuti aturan.
class OrderOnlineSettingPage extends StatefulWidget {
  final String outletId;
  const OrderOnlineSettingPage({super.key, required this.outletId});

  @override
  State<OrderOnlineSettingPage> createState() => _OrderOnlineSettingPageState();
}

class _OrderOnlineSettingPageState extends State<OrderOnlineSettingPage> {
  bool _value = true;
  bool _scheduleEnabled = false;
  String _openTime = '10:00';
  String _closeTime = '22:00';
  bool _requireCustomerName = false;
  bool _allowNotes = true;
  bool _autoConfirm = false;
  final _closedMessageCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  bool get _canEdit {
    final auth = context.read<AuthBloc>().state;
    if (auth is! AuthAuthenticated) return false;
    return auth.profile.role.hasAdminAccess;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _closedMessageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('outlets')
          .select('settings')
          .eq('id', widget.outletId)
          .single();
      final settings = (row['settings'] as Map?)?.cast<String, dynamic>() ?? {};
      _value = settings['self_order_enabled'] as bool? ?? true;
      _scheduleEnabled =
          settings['self_order_schedule_enabled'] as bool? ?? false;
      _openTime = settings['self_order_open_time'] as String? ?? '10:00';
      _closeTime = settings['self_order_close_time'] as String? ?? '22:00';
      _requireCustomerName =
          settings['self_order_require_name'] as bool? ?? false;
      _allowNotes = settings['self_order_allow_notes'] as bool? ?? true;
      _autoConfirm = settings['self_order_auto_confirm'] as bool? ?? false;
      _closedMessageCtrl.text =
          settings['self_order_closed_message'] as String? ?? '';
    } catch (_) {
      // Default aktif menjaga kompatibilitas outlet lama bila pembacaan gagal.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setTime(bool opening) async {
    final current = _parseTime(opening ? _openTime : _closeTime);
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
      helpText: opening ? 'Jam buka order online' : 'Jam tutup order online',
    );
    if (picked == null || !mounted) return;
    final value =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (opening) {
        _openTime = value;
      } else {
        _closeTime = value;
      }
    });
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 10,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  Future<void> _save() async {
    if (!_canEdit || _saving) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc(
        'update_outlet_settings',
        params: {
          'p_outlet_id': widget.outletId,
          'p_patch': {
            'self_order_enabled': _value,
            'self_order_schedule_enabled': _scheduleEnabled,
            'self_order_open_time': _openTime,
            'self_order_close_time': _closeTime,
            'self_order_closed_message': _closedMessageCtrl.text.trim(),
            'self_order_require_name': _requireCustomerName,
            'self_order_allow_notes': _allowNotes,
            'self_order_auto_confirm': _autoConfirm,
          },
        },
      );
      if (mounted) _snack('Pengaturan Order Online tersimpan');
    } on PostgrestException catch (e) {
      if (mounted) {
        _snack(
          e.code == '42501'
              ? 'Hanya owner/admin yang dapat mengubah pengaturan ini'
              : 'Gagal menyimpan — cek koneksi',
          error: true,
        );
      }
    } catch (_) {
      if (mounted) _snack('Gagal menyimpan — cek koneksi', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? const Color(0xFF991B1B)
            : const Color(0xFF111111),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Order Online',
      onSave: _save,
      saving: _saving,
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: SK.ink))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                skCard([
                  SKToggleRow(
                    label: 'Terima pesanan online',
                    desc: _value
                        ? 'Aktif untuk seluruh outlet'
                        : 'Ditutup untuk seluruh outlet',
                    value: _value,
                    enabled: _canEdit,
                    onChanged: (v) => setState(() => _value = v),
                  ),
                ]),
                const SizedBox(height: 20),
                skSectionLabel('Jam Operasional'),
                skCard([
                  SKToggleRow(
                    label: 'Batasi berdasarkan jam',
                    desc:
                        'Pelanggan hanya dapat memesan pada jam yang ditentukan.',
                    value: _scheduleEnabled,
                    enabled: _canEdit,
                    onChanged: (v) => setState(() => _scheduleEnabled = v),
                  ),
                  _timeRow('Jam buka', _openTime, () => _setTime(true)),
                  _timeRow('Jam tutup', _closeTime, () => _setTime(false)),
                ]),
                const SizedBox(height: 20),
                skSectionLabel('Perilaku Order'),
                skCard([
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _closedMessageCtrl,
                      enabled: _canEdit,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Pesan saat order ditutup',
                        hintText:
                            'Order online sedang tutup. Silakan datang langsung.',
                      ),
                    ),
                  ),
                  SKToggleRow(
                    label: 'Wajib nama pelanggan',
                    value: _requireCustomerName,
                    enabled: _canEdit,
                    onChanged: (v) => setState(() => _requireCustomerName = v),
                  ),
                  SKToggleRow(
                    label: 'Izinkan catatan pesanan',
                    value: _allowNotes,
                    enabled: _canEdit,
                    onChanged: (v) => setState(() => _allowNotes = v),
                  ),
                  SKToggleRow(
                    label: 'Konfirmasi otomatis',
                    desc: 'Order langsung dikonfirmasi dan masuk alur dapur.',
                    value: _autoConfirm,
                    enabled: _canEdit,
                    onChanged: (v) => setState(() => _autoConfirm = v),
                  ),
                ]),
                if (!_canEdit)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        border: Border.all(color: const Color(0xFFFED7AA)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: Color(0xFF9A3412),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Pengaturan hanya dapat diubah oleh owner/admin. '
                                'Hubungi owner jika ada perubahan yang diperlukan.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9A3412),
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                  child: Text(
                    _canEdit
                        ? 'Perubahan berlaku untuk semua meja QR dan semua perangkat di outlet ini.'
                        : 'Hanya owner/admin yang dapat mengubah pengaturan outlet.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: SK.muted,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _timeRow(String label, String value, VoidCallback onTap) => ListTile(
    title: Text(label, style: const TextStyle(fontSize: 14)),
    trailing: TextButton(
      onPressed: _canEdit ? onTap : null,
      child: Text(value),
    ),
  );
}

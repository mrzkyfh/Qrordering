import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/settings_kit.dart';
import '../../../../shared/widgets/receipt_preview.dart';
import '../../../../shared/services/receipt_builder.dart' show OutletReceiptInfo;
import '../../../../shared/models/enums.dart' show PaymentMethod;

/// Struk & Biaya — atur tampilan struk + pajak & service charge.
/// Disimpan di outlets.settings (JSONB). Akses: owner/admin.
class StrukBiayaPage extends StatefulWidget {
  final String outletId;
  const StrukBiayaPage({super.key, required this.outletId});
  @override
  State<StrukBiayaPage> createState() => _StrukBiayaPageState();
}

class _StrukBiayaPageState extends State<StrukBiayaPage> {
  Map<String, dynamic> _s = {};
  final _footer = TextEditingController();
  final _taxName = TextEditingController();
  final _taxPct = TextEditingController();
  final _svcPct = TextEditingController();
  final _businessName = TextEditingController();
  final _province = TextEditingController();
  final _country = TextEditingController();
  final _logoUrl = TextEditingController();
  final _customHeaderText = TextEditingController();
  int _rounding = 0;
  String _logoStyle = 'normal';
  String _customHeaderAlign = 'center';
  List<Map<String, dynamic>> _customHeaderFields = [];
  List<Map<String, dynamic>> _customBodyFields = [];
  bool _loading = true;
  bool _saving = false;

  // Toggle struk: key settings -> label.
  static const _toggles = <String, String>{
    'receipt_show_logo': 'Tampilkan Logo',
    'receipt_show_business_name': 'Nama Bisnis',
    'receipt_show_outlet_name': 'Nama Outlet',
    'receipt_show_address': 'Alamat',
    'receipt_show_phone': 'Telepon',
    'receipt_show_city': 'Kota',
    'receipt_show_province': 'Provinsi',
    'receipt_show_country': 'Negara',
    'receipt_show_order_number': 'No Nota',
    'receipt_show_order_time': 'Waktu',
    'receipt_show_cashier': 'Kasir',
    'receipt_show_cashier_pay': 'Kasir Pembayaran',
    'receipt_show_customer': 'Customer',
    'receipt_show_waiter': 'Pelayan',
    'receipt_show_order_type': 'Jenis Order',
    'receipt_show_order_name': 'Nama Order',
    'receipt_show_table': 'Nomor Meja',
    'receipt_limit_print': 'Batasi Cetak Ulang',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _footer.dispose();
    _taxName.dispose();
    _taxPct.dispose();
    _svcPct.dispose();
    _businessName.dispose();
    _province.dispose();
    _country.dispose();
    _logoUrl.dispose();
    _customHeaderText.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('outlets')
          .select('settings')
          .eq('id', widget.outletId)
          .single();
      _s = Map<String, dynamic>.from((row['settings'] as Map?) ?? {});
    } catch (_) {
      /* abaikan */
    }
    _footer.text = (_s['receipt_footer'] as String?) ?? '';
    _taxName.text = (_s['tax_name'] as String?) ?? 'PPN';
    _taxPct.text = ((_s['tax_percent'] as num?) ?? 0).toString();
    _svcPct.text = ((_s['service_charge_percent'] as num?) ?? 0).toString();
    _businessName.text = (_s['business_name'] as String?) ?? '';
    _province.text = (_s['receipt_province'] as String?) ?? '';
    _country.text = (_s['receipt_country'] as String?) ?? '';
    _logoUrl.text = (_s['receipt_logo_url'] as String?) ?? '';
    _customHeaderText.text =
        (_s['receipt_custom_header_text'] as String?) ?? '';
    _logoStyle = (_s['receipt_logo_style'] as String?) ?? 'normal';
    _customHeaderAlign =
        (_s['receipt_custom_header_align'] as String?) ?? 'center';
    _customHeaderFields = _readFields(_s['receipt_custom_header_fields']);
    _customBodyFields = _readFields(_s['receipt_custom_body_fields']);
    _rounding = ((_s['rounding'] as num?) ?? 0).toInt();
    if (mounted) setState(() => _loading = false);
  }

  bool _b(String k, {bool def = true}) => _s[k] as bool? ?? def;

  /// Rakit OutletReceiptInfo dari state HIDUP (setelan yang sedang diedit) →
  /// pratinjau mencerminkan perubahan sebelum disimpan. Identitas outlet
  /// (nama/alamat) memakai contoh karena halaman ini hanya menyimpan setelan.
  OutletReceiptInfo _previewInfo() {
    final s = <String, dynamic>{
      ..._s,
      for (final k in _toggles.keys)
        k: _b(k, def: k != 'receipt_show_order_time'),
      'receipt_footer': _footer.text.trim(),
      'receipt_province': _province.text.trim(),
      'receipt_country': _country.text.trim(),
      'receipt_logo_url':
          _logoUrl.text.trim().isEmpty ? null : _logoUrl.text.trim(),
      'receipt_logo_style': _logoStyle,
      'receipt_custom_header': _b('receipt_custom_header', def: false),
      'receipt_custom_header_text': _customHeaderText.text.trim(),
      'receipt_custom_header_align': _customHeaderAlign,
      'receipt_custom_header_fields': _customHeaderFields,
      'receipt_custom_body_fields': _customBodyFields,
      'service_charge_percent': double.tryParse(_svcPct.text.trim()) ?? 0,
      'tax_name': _taxName.text.trim().isEmpty ? 'PPN' : _taxName.text.trim(),
      'tax_percent': double.tryParse(_taxPct.text.trim()) ?? 0,
    };
    final biz = _businessName.text.trim();
    return OutletReceiptInfo.fromMap({
      'name': biz.isEmpty ? 'Nama Toko Anda' : biz,
      'address': 'Jl. Contoh No. 1',
      'phone': '08123456789',
      'city': 'Jakarta',
      'settings': s,
    });
  }

  List<Map<String, dynamic>> _readFields(dynamic raw) => raw is List
      ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : [];

  Future<void> _openOwnerPanel(String section) async {
    final uri = Uri.parse('https://qrordering.my.id/admin/$section');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      _snack('Buka Owner Panel untuk mengubah pengaturan pajak', error: true);
    }
  }

  void _taxOwnerNotice() {
    _snack('Pajak hanya dapat diubah dari Owner Panel → Pajak');
  }

  Future<void> _save() async {
    final service = double.tryParse(_svcPct.text.trim());
    if (service == null || service < 0 || service > 100) {
      _snack('Service charge harus antara 0–100%', error: true);
      return;
    }
    setState(() => _saving = true);
    // Kirim HANYA kunci yang dimiliki halaman ini, bukan seluruh blob settings.
    // Menulis balik seluruh blob akan menghapus perubahan yang dibuat dari
    // owner-panel sejak halaman ini dibuka (mis. logo struk, custom header).
    final patch = <String, dynamic>{
      for (final k in _toggles.keys)
        k: _b(k, def: k != 'receipt_show_order_time'),
      'receipt_footer': _footer.text.trim(),
      'business_name': _businessName.text.trim(),
      'receipt_province': _province.text.trim(),
      'receipt_country': _country.text.trim(),
      'receipt_logo_url': _logoUrl.text.trim().isEmpty
          ? null
          : _logoUrl.text.trim(),
      'receipt_logo_style': _logoStyle,
      'receipt_custom_header': _b('receipt_custom_header', def: false),
      'receipt_custom_header_text': _customHeaderText.text.trim(),
      'receipt_custom_header_align': _customHeaderAlign,
      'receipt_custom_header_fields': _customHeaderFields,
      'receipt_custom_body_fields': _customBodyFields,
      'service_charge_percent': service,
      'rounding': _rounding,
    };
    try {
      // Lewat RPC, bukan UPDATE langsung: UPDATE yang ditolak RLS cocok 0 baris
      // dan dianggap SUKSES oleh PostgREST — dulu kasir dapat notifikasi
      // "tersimpan" padahal tak ada yang berubah. RPC melempar 42501.
      final merged = await Supabase.instance.client.rpc(
        'update_outlet_settings',
        params: {'p_outlet_id': widget.outletId, 'p_patch': patch},
      );
      if (merged is Map) _s = Map<String, dynamic>.from(merged);
      if (!mounted) return;
      _snack('Pengaturan struk & biaya tersimpan');
    } on PostgrestException catch (e) {
      if (!mounted) return;
      _snack(
        e.code == '42501'
            ? 'Hanya owner/admin yang bisa mengubah pengaturan ini'
            : 'Gagal menyimpan: ${e.message}',
        error: true,
      );
    } catch (_) {
      if (!mounted) return;
      _snack('Gagal menyimpan — cek koneksi', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m),
        backgroundColor: error
            ? const Color(0xFF991B1B)
            : const Color(0xFF111111),
      ),
    );
  }

  Widget _selectRow({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, color: SK.ink),
          ),
        ),
        DropdownButton<String>(
          value: items.containsKey(value) ? value : items.keys.first,
          underline: const SizedBox.shrink(),
          items: items.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    ),
  );

  Widget _customFieldsEditor({
    required String title,
    required List<Map<String, dynamic>> fields,
    required ValueChanged<List<Map<String, dynamic>>> onChanged,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < fields.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('${fields[i]['id']}-label'),
                    initialValue: fields[i]['label']?.toString() ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final next = List<Map<String, dynamic>>.from(fields);
                      next[i] = {...next[i], 'label': v};
                      onChanged(next);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('${fields[i]['id']}-value'),
                    initialValue: fields[i]['value']?.toString() ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Nilai',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final next = List<Map<String, dynamic>>.from(fields);
                      next[i] = {...next[i], 'value': v};
                      onChanged(next);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Hapus field',
                  onPressed: () {
                    final next = List<Map<String, dynamic>>.from(fields)
                      ..removeAt(i);
                    onChanged(next);
                  },
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => onChanged([
            ...fields,
            {
              'id': DateTime.now().microsecondsSinceEpoch.toString(),
              'label': '',
              'value': '',
              'visible': true,
            },
          ]),
          icon: const Icon(Icons.add, size: 17),
          label: const Text('Tambah Field'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Struk & Biaya',
      onSave: _save,
      saving: _saving,
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: SK.ink))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                skSectionLabel('Pratinjau'),
                // Pratinjau HIDUP — ikut berubah saat setelan di bawah diubah.
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFECECEC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: ReceiptPreview(
                      outlet: _previewInfo(),
                      order: sampleReceiptOrder(),
                      paymentMethod: PaymentMethod.cash,
                      cashReceived: 100000,
                      cashierName: 'Kasir',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text('Contoh data — struk asli memakai transaksi nyata',
                      style: TextStyle(
                          fontSize: 11, color: SK.ink.withValues(alpha: 0.5))),
                ),
                const SizedBox(height: 16),
                skSectionLabel('Tampilan Struk'),
                skCard([
                  for (final e in _toggles.entries)
                    SKToggleRow(
                      label: e.value,
                      value: _b(e.key, def: e.key != 'receipt_show_order_time'),
                      enabled:
                          !e.key.startsWith('receipt_show_') ||
                          e.key == 'receipt_show_logo' ||
                          e.key == 'receipt_show_business_name' ||
                          e.key == 'receipt_show_outlet_name' ||
                          e.key == 'receipt_show_address' ||
                          e.key == 'receipt_show_phone' ||
                          e.key == 'receipt_show_city' ||
                          e.key == 'receipt_show_province' ||
                          e.key == 'receipt_show_country' ||
                          e.key == 'receipt_show_order_number' ||
                          e.key == 'receipt_show_order_time' ||
                          e.key == 'receipt_show_cashier' ||
                          e.key == 'receipt_show_cashier_pay' ||
                          e.key == 'receipt_show_customer' ||
                          e.key == 'receipt_show_waiter' ||
                          e.key == 'receipt_show_order_type' ||
                          e.key == 'receipt_show_order_name' ||
                          e.key == 'receipt_show_table' ||
                          e.key == 'receipt_limit_print',
                      onChanged: (v) => setState(() => _s[e.key] = v),
                    ),
                  // Footer struk — di dalam card, setelah semua toggle.
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _footerField(),
                  ),
                ]),
                const SizedBox(height: 22),
                skSectionLabel('Header & Custom Field'),
                skCard([
                  SKField(label: 'Nama Bisnis', controller: _businessName),
                  SKField(label: 'Provinsi', controller: _province),
                  SKField(label: 'Negara', controller: _country),
                  SKField(
                    label: 'URL Logo (opsional)',
                    controller: _logoUrl,
                    hint: 'Gunakan upload logo dari Owner Panel',
                  ),
                  _selectRow(
                    label: 'Gaya Logo',
                    value: _logoStyle,
                    items: const {'normal': 'Normal', 'full': 'Lebar penuh'},
                    onChanged: (v) => setState(() => _logoStyle = v),
                  ),
                  SKToggleRow(
                    label: 'Header Custom',
                    value: _b('receipt_custom_header', def: false),
                    onChanged: (v) =>
                        setState(() => _s['receipt_custom_header'] = v),
                  ),
                  SKField(
                    label: 'Teks Header Custom',
                    controller: _customHeaderText,
                  ),
                  _selectRow(
                    label: 'Perataan Header',
                    value: _customHeaderAlign,
                    items: const {
                      'left': 'Kiri',
                      'center': 'Tengah',
                      'right': 'Kanan',
                    },
                    onChanged: (v) => setState(() => _customHeaderAlign = v),
                  ),
                  _customFieldsEditor(
                    title: 'Field Header Tambahan',
                    fields: _customHeaderFields,
                    onChanged: (v) => setState(() => _customHeaderFields = v),
                  ),
                  _customFieldsEditor(
                    title: 'Field Body Tambahan',
                    fields: _customBodyFields,
                    onChanged: (v) => setState(() => _customBodyFields = v),
                  ),
                ]),
                const SizedBox(height: 22),
                skSectionLabel('Pajak & Service Charge'),
                skCard([
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 18,
                          color: SK.muted,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Pengaturan pajak hanya dapat diubah di Owner Panel agar seluruh perangkat memakai tarif yang sama.',
                            style: TextStyle(
                              fontSize: 12,
                              color: SK.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _openOwnerPanel('taxes'),
                          child: const Text('Buka'),
                        ),
                      ],
                    ),
                  ),
                  SKToggleRow(
                    label: 'Pajak Aktif',
                    value: _b('tax_active'),
                    enabled: false,
                    onChanged: (_) => _taxOwnerNotice(),
                  ),
                  SKToggleRow(
                    label: 'Harga Sudah Termasuk Pajak',
                    value: _b('tax_inclusive', def: false),
                    enabled: false,
                    onChanged: (_) => _taxOwnerNotice(),
                  ),
                  // Grid 2 kolom dgn garis pemisah vertikal (border-kanan).
                  Row(
                    children: [
                      Expanded(
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(color: SK.borderLt),
                            ),
                          ),
                          child: SKField(
                            label: 'Nama Pajak',
                            controller: _taxName,
                            enabled: false,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SKField(
                          label: 'Pajak (%)',
                          controller: _taxPct,
                          enabled: false,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SKField(
                    label: 'Service Charge (%)',
                    controller: _svcPct,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ]),
                const SizedBox(height: 22),
                skSectionLabel('Pembulatan Total'),
                skCard([
                  _roundingOption(0, 'Tidak ada pembulatan'),
                  _roundingOption(100, 'Ke Rp 100 terdekat'),
                  _roundingOption(500, 'Ke Rp 500 terdekat'),
                  _roundingOption(1000, 'Ke Rp 1.000 terdekat'),
                ]),
              ],
            ),
    );
  }

  Widget _footerField() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F8F8),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SK.border, width: 1.5),
    ),
    child: TextField(
      controller: _footer,
      minLines: 2,
      maxLines: 3,
      style: const TextStyle(fontSize: 13, color: SK.ink),
      decoration: const InputDecoration(
        isDense: true,
        filled: false,
        fillColor: Colors.transparent,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(vertical: 6),
        hintText: 'Catatan kaki struk (footer)',
        hintStyle: TextStyle(color: SK.faint),
      ),
    ),
  );

  Widget _roundingOption(int value, String label) => InkWell(
    onTap: () => setState(() => _rounding = value),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            _rounding == value
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 20,
            color: _rounding == value ? SK.ink : SK.faint,
          ),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 14, color: SK.ink)),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/thousands_formatter.dart';
import '../widgets/settings_kit.dart';

/// Kelola Promo (CRUD) — owner/admin. Tabel `promos` (RLS owner/admin).
class PromoPage extends StatefulWidget {
  final String outletId;
  const PromoPage({super.key, required this.outletId});
  @override
  State<PromoPage> createState() => _PromoPageState();
}

class _PromoPageState extends State<PromoPage> {
  List<Map<String, dynamic>> _promos = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('promos')
          .select()
          .eq('outlet_id', widget.outletId)
          .order('created_at', ascending: false);
      _promos = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      /* abaikan */
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([Map<String, dynamic>? promo]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _PromoEditPage(outletId: widget.outletId, promo: promo),
      ),
    );
    if (saved == true) _load();
  }

  String _typeLabel(String t) => switch (t) {
    'percentage' => 'Persentase',
    'fixed' => 'Potongan Tetap',
    'bundling' => 'Bundling',
    'bogo' => 'Beli 1 Gratis 1',
    _ => t,
  };

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Promo',
      floatingActionButton: SKFab(label: 'Tambah Promo', onTap: () => _edit()),
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: SK.ink))
          : _promos.isEmpty
          ? const Center(
              child: Text(
                'Belum ada promo.\nTap tombol untuk menambah.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SK.muted),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                skCard([for (final p in _promos) _promoRow(p)]),
              ],
            ),
    );
  }

  Widget _promoRow(Map<String, dynamic> p) {
    final type = p['type'] as String? ?? '';
    final val = (p['value'] as num?)?.toDouble() ?? 0;
    final active = p['is_active'] as bool? ?? true;
    final valStr = type == 'percentage'
        ? '${val.toStringAsFixed(val == val.roundToDouble() ? 0 : 1)}%'
        : CurrencyFormatter.format(val);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _edit(p),
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
                child: Icon(
                  Icons.sell_outlined,
                  size: 17,
                  color: active ? SK.iconStroke : SK.faint,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p['name'] as String? ?? '-',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: SK.ink,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        '${_typeLabel(type)} · $valStr${active ? '' : ' · nonaktif'}',
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

class _PromoEditPage extends StatefulWidget {
  final String outletId;
  final Map<String, dynamic>? promo;
  const _PromoEditPage({required this.outletId, this.promo});
  @override
  State<_PromoEditPage> createState() => _PromoEditPageState();
}

class _PromoEditPageState extends State<_PromoEditPage> {
  static const _typeLabels = <String, String>{
    'percentage': 'Persentase',
    'fixed': 'Potongan Tetap',
    'bundling': 'Bundling',
    'bogo': 'Beli 1 Gratis 1',
  };

  final _name = TextEditingController();
  final _description = TextEditingController();
  final _value = TextEditingController();
  final _minOrder = TextEditingController(text: '0');
  final _maxDiscount = TextEditingController();
  final _usageLimit = TextEditingController();
  final _startDate = TextEditingController();
  final _endDate = TextEditingController();
  String _type = 'percentage';
  bool _active = true;
  bool _saving = false;

  bool get _isEdit => widget.promo != null;

  @override
  void initState() {
    super.initState();
    final p = widget.promo;
    if (p != null) {
      _name.text = p['name'] as String? ?? '';
      _description.text = p['description'] as String? ?? '';
      _type = p['type'] as String? ?? 'percentage';
      final v = (p['value'] as num?) ?? 0;
      // Nilai uang (fixed) ditampilkan dengan pemisah ribuan; persen apa adanya.
      _value.text = _type == 'fixed' ? formatThousands(v) : '$v';
      _minOrder.text = formatThousands((p['min_order'] as num?) ?? 0);
      final maxD = p['max_discount'] as num?;
      _maxDiscount.text = maxD == null ? '' : formatThousands(maxD);
      _usageLimit.text = (p['usage_limit'] as num?)?.toString() ?? '';
      _startDate.text = _dateOnly(p['start_date']);
      _endDate.text = _dateOnly(p['end_date']);
      _active = p['is_active'] as bool? ?? true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _value.dispose();
    _minOrder.dispose();
    _maxDiscount.dispose();
    _usageLimit.dispose();
    _startDate.dispose();
    _endDate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Nama promo wajib diisi', error: true);
      return;
    }
    // Persentase = desimal biasa; potongan tetap = nilai uang (pemisah ribuan).
    final value = _type == 'fixed'
        ? parseThousands(_value.text)
        : (double.tryParse(_value.text.trim()) ?? 0);
    if (value <= 0) {
      _snack('Nilai promo harus > 0', error: true);
      return;
    }
    final start = _startDate.text.trim();
    final end = _endDate.text.trim();
    if (start.isNotEmpty && !_isIsoDate(start) ||
        end.isNotEmpty && !_isIsoDate(end)) {
      _snack('Format tanggal tidak valid', error: true);
      return;
    }
    if (start.isNotEmpty && end.isNotEmpty && end.compareTo(start) < 0) {
      _snack('Tanggal berakhir harus setelah tanggal mulai', error: true);
      return;
    }
    setState(() => _saving = true);
    final data = {
      'outlet_id': widget.outletId,
      'name': _name.text.trim(),
      'description': _description.text.trim().isEmpty
          ? null
          : _description.text.trim(),
      'type': _type,
      'value': value,
      'min_order': parseThousands(_minOrder.text),
      'max_discount': _maxDiscount.text.trim().isEmpty
          ? null
          : parseThousands(_maxDiscount.text),
      'usage_limit': _usageLimit.text.trim().isEmpty
          ? null
          : int.tryParse(_usageLimit.text.trim()),
      'start_date': start.isEmpty ? null : start,
      'end_date': end.isEmpty ? null : end,
      'is_active': _active,
    };
    try {
      final client = Supabase.instance.client;
      if (_isEdit) {
        // .select() WAJIB: UPDATE yang disaring RLS (kasir/manajer — hanya
        // owner/admin yang boleh, lihat promos_update di 005) cocok 0 baris dan
        // dibalas SUKSES oleh PostgREST. Tanpa cek ini halaman menutup dengan
        // "berhasil" padahal promo tak berubah sedikit pun. INSERT tak perlu
        // pola ini: pelanggaran WITH CHECK justru melempar 403 (tertangkap).
        final rows = await client
            .from('promos')
            .update(data)
            .eq('id', widget.promo!['id'])
            .select('id');
        if (!mounted) return;
        if ((rows as List).isEmpty) {
          setState(() => _saving = false);
          _snack('Hanya owner/admin yang bisa mengubah promo', error: true);
          return;
        }
      } else {
        await client.from('promos').insert(data);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Gagal menyimpan (cek izin/akses)', error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus promo?'),
        content: Text('Hapus "${_name.text}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF115E59),
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Sama seperti _save: DELETE yang disaring RLS mengembalikan 0 baris tanpa
      // error → tanpa .select() promo tampak "terhapus" padahal masih ada.
      final rows = await Supabase.instance.client
          .from('promos')
          .delete()
          .eq('id', widget.promo!['id'])
          .select('id');
      if (!mounted) return;
      if ((rows as List).isEmpty) {
        _snack('Hanya owner/admin yang bisa menghapus promo', error: true);
        return;
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      _snack('Gagal menghapus', error: true);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Promo' : 'Promo Baru'),
        actions: [
          if (_isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '...' : 'Simpan'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('Nama Promo', _name),
          const SizedBox(height: 14),
          _field('Deskripsi (opsional)', _description, maxLines: 2),
          const SizedBox(height: 14),
          const Text(
            'Jenis',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _typeLabels.containsKey(_type) ? _type : 'percentage',
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: _typeLabels.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 14),
          _field(
            _type == 'percentage' ? 'Nilai (%)' : 'Potongan (Rp)',
            _value,
            isNum: true,
            money: _type == 'fixed',
          ),
          const SizedBox(height: 14),
          _field('Minimum Order (Rp)', _minOrder, isNum: true, money: true),
          if (_type == 'percentage') ...[
            const SizedBox(height: 14),
            _field(
              'Maks. Potongan (Rp, opsional)',
              _maxDiscount,
              isNum: true,
              money: true,
            ),
          ],
          const SizedBox(height: 14),
          _field('Batas Pemakaian (opsional)', _usageLimit, isNum: true),
          const SizedBox(height: 14),
          _dateField('Mulai Promo (opsional)', _startDate),
          const SizedBox(height: 14),
          _dateField('Berakhir (opsional)', _endDate),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aktif'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    bool isNum = false,
    bool money = false,
    int maxLines = 1,
  }) => TextField(
    controller: c,
    maxLines: maxLines,
    keyboardType: isNum
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    inputFormatters: money ? [ThousandsInputFormatter()] : null,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _dateField(String label, TextEditingController c) => TextField(
    controller: c,
    readOnly: true,
    onTap: () => _pickDate(c),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
    ),
  );

  Future<void> _pickDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: initial,
    );
    if (picked != null) controller.text = _dateOnly(picked);
  }

  static String _dateOnly(dynamic value) {
    if (value == null) return '';
    final raw = value.toString();
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  static bool _isIsoDate(String value) {
    final date = DateTime.tryParse(value);
    return date != null && value.length == 10;
  }
}

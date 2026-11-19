import 'dart:async';
import 'package:bluetooth_print_plus/bluetooth_print_plus.dart' hide Alignment;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart' show PaperSize;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/kitchen_ticket_builder.dart';

// Aksen merah brand (seragam dgn dialog "Pilih Jenis Perangkat") + netral slate.
const _teal = Color(0xFF0F766E);
const _muted = Color(0xFF94A3B8);

const _jenisLabels = {
  'kasir': 'Printer Kasir',
  'dapur': 'Printer Dapur',
  'label': 'Printer Label',
  'alamat': 'Printer Alamat',
  'terpusat': 'Printer Terpusat',
  'scanner': 'Barcode Scanner',
};
const _connLabels = {
  'bt': 'Bluetooth',
  'lan': 'WiFi / LAN',
  'usb': 'USB / Serial',
};

/// IPv4 bertitik-empat yang tiap oktetnya 0–255.
///
/// `int.tryParse` saja tidak cukup: ia menerima '192.168.1.999' dan '1.2.3'
/// tanpa keluhan, dan alamat salah itu baru ketahuan saat struk tak keluar.
@visibleForTesting
bool isValidIpv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    // '01' / '007' bukan penulisan yang sah dan bisa ditafsirkan oktal.
    if (p.length > 1 && p.startsWith('0')) return false;
  }
  return true;
}

/// Label daftar harus mengikuti peran yang benar-benar aktif, bukan hanya field
/// `jenis` lama. Satu printer fisik dapat menjalankan Struk dan Dapur sekaligus.
@visibleForTesting
String printerRoleLabel(SavedPrinter printer) {
  if (printer.strukEnabled && printer.dapurEnabled) {
    return 'Printer Struk + Dapur';
  }
  if (printer.dapurEnabled) return 'Printer Dapur';
  if (printer.strukEnabled) return 'Printer Struk';
  return _jenisLabels[printer.jenis] ?? printer.jenis;
}

/// Terapkan pilihan jenis dari wizard ke printer fisik yang sudah terdaftar.
///
/// Tanpa ini, memilih perangkat Struk yang sama sebagai "Printer Dapur" hanya
/// membuka konfigurasi lamanya; toggle Dapur tetap mati walaupun pengguna sudah
/// memilih jenis Dapur di langkah sebelumnya.
@visibleForTesting
SavedPrinter printerWithAddedRole(SavedPrinter printer, String jenis) {
  if (jenis == 'dapur') {
    return printer.copyWith(dapurEnabled: true, autoOrder: true, enabled: true);
  }
  if (jenis == 'kasir') {
    return printer.copyWith(strukEnabled: true, enabled: true);
  }
  return printer.copyWith(jenis: jenis, enabled: true);
}

/// Layar "Perangkat" ala Majoo — daftar perangkat bergaya tabel + tambah.
class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key});
  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  final _printer = PrinterService();
  final _searchCtrl = TextEditingController();
  List<SavedPrinter> _devices = const [];
  bool _loading = true;
  String _query = '';
  String? _connectedMac; // MAC printer BT yang sedang terhubung
  String? _defaultPrinterId;
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    _printer.init();
    _connectedMac = _printer.connectedDevice?.address;
    _connSub = _printer.connectedStream.listen((_) {
      if (mounted) {
        setState(() => _connectedMac = _printer.connectedDevice?.address);
      }
    });
    _load();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // Printer LAN dianggap selalu siap (tanpa pairing); BT terhubung bila MAC cocok.
  bool _isConnected(SavedPrinter p) => p.isLan || _connectedMac == p.mac;

  Future<void> _load() async {
    final list = await _printer.listPrinters();
    final defaultId = await _printer.defaultPrinterId();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _defaultPrinterId = defaultId;
      _loading = false;
    });
  }

  String get _outletId {
    final a = context.read<AuthBloc>().state;
    return a is AuthAuthenticated ? a.profile.outletId ?? '' : '';
  }

  List<SavedPrinter> get _filtered => _query.isEmpty
      ? _devices
      : _devices
            .where((d) => d.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

  Future<void> _addDevice() async {
    final jenis = await _pickJenisPerangkat(context);
    if (jenis == null || !mounted) return;
    final conn = await _pickKoneksi(context);
    if (conn == null || !mounted) return;

    String name = _jenisLabels[jenis] ?? 'Printer';
    String mac = '';
    String host = '';
    int port = 9100;

    if (conn == 'bt') {
      final picked = await Navigator.of(context)
          .push<({String name, String mac})>(
            MaterialPageRoute(
              builder: (_) =>
                  _BtScanPage(title: _jenisLabels[jenis] ?? 'Printer'),
            ),
          );
      if (picked == null || !mounted) return;
      name = picked.name.isEmpty ? name : picked.name;
      mac = picked.mac;
    } else {
      final lan = await _inputLan();
      if (lan == null || !mounted) return;
      name = lan.name;
      host = lan.host;
      port = lan.port;
    }

    // Printer fisik ini sudah terdaftar? Jangan buat entri baru yang menimpa —
    // buka pengaturan yang ADA agar user tinggal menyalakan peran kedua (mis.
    // Dapur) di tabnya. Tanpa ini, menambah printer yang sama untuk peran kedua
    // terlihat seperti menghapus printer lama.
    final matches = _devices.where((p) {
      if (conn == 'lan') return p.isLan && p.host == host && p.port == port;
      return !p.isLan &&
          p.mac.isNotEmpty &&
          p.mac.toUpperCase() == mac.toUpperCase();
    }).toList();
    if (matches.isNotEmpty) {
      final printerWithRole = printerWithAddedRole(matches.first, jenis);
      _snack(
        jenis == 'dapur'
            ? 'Printer sudah terdaftar. Peran Dapur sudah dipilih; tekan Simpan untuk menerapkan.'
            : 'Printer sudah terdaftar. Peran Struk sudah dipilih; tekan Simpan untuk menerapkan.',
      );
      await _openConfig(printerWithRole);
      return;
    }

    final printer = SavedPrinter(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      mac: mac,
      type: conn,
      host: host,
      port: port,
      jenis: jenis,
      // Peran awal mengikuti jenis yang dipilih di wizard; bisa diubah bebas
      // (multi-peran) di tab Struk/Dapur.
      strukEnabled: jenis != 'dapur',
      dapurEnabled: jenis == 'dapur',
      autoOrder: jenis == 'dapur',
    );
    if (!mounted) return;
    final saved = await Navigator.of(context).push<SavedPrinter>(
      MaterialPageRoute(
        builder: (_) => DeviceConfigPage(printer: printer, outletId: _outletId),
      ),
    );
    if (saved == null) return;
    _clearSearch();
    await _load();
    _snack('${printerRoleLabel(saved)} berhasil disimpan dan ditampilkan.');
  }

  Future<({String name, String host, int port})?> _inputLan() async {
    final nameCtrl = TextEditingController();
    final ipCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '9100');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Printer WiFi / LAN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Nama'),
              ),
              TextField(
                controller: ipCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'IP (mis. 192.168.1.50)',
                ),
              ),
              TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lanjut', style: TextStyle(color: _teal)),
            ),
          ],
        ),
      );
      if (ok != true) return null;
      final name = nameCtrl.text.trim();
      final ip = ipCtrl.text.trim();
      if (name.isEmpty || ip.isEmpty) {
        _snack('Nama & IP wajib diisi', error: true);
        return null;
      }
      // Divalidasi di sini, bukan nanti: IP salah ketik hanya ketahuan saat
      // cetak gagal — dan `mac`/`host` tak bisa disunting setelah tersimpan,
      // jadi satu typo memaksa hapus & ulang dari awal.
      if (!isValidIpv4(ip)) {
        _snack('Alamat IP tidak valid (contoh: 192.168.1.50)', error: true);
        return null;
      }
      final port = int.tryParse(portCtrl.text.trim()) ?? 9100;
      if (port < 1 || port > 65535) {
        _snack('Port harus antara 1–65535 (umumnya 9100)', error: true);
        return null;
      }
      return (name: name, host: ip, port: port);
    } finally {
      // Dulu ketiganya tak pernah di-dispose → bocor tiap kali dialog dibuka.
      nameCtrl.dispose();
      ipCtrl.dispose();
      portCtrl.dispose();
    }
  }

  Future<void> _openConfig(SavedPrinter p) async {
    final saved = await Navigator.of(context).push<SavedPrinter>(
      MaterialPageRoute(
        builder: (_) => DeviceConfigPage(printer: p, outletId: _outletId),
      ),
    );
    if (saved != null) _clearSearch();
    // Tetap muat ulang saat halaman ditutup tanpa hasil, karena perangkat bisa
    // saja baru dihapus dari menu Aksi.
    await _load();
    if (saved == null) return;
    _snack('${printerRoleLabel(saved)} berhasil diperbarui.');
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _query = '';
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error
            ? const Color(0xFF991B1B)
            : const Color(0xFF111111),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            _topbar(),
            _searchBar(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _filtered.isEmpty
                  ? _emptyState()
                  : _list(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Topbar ──
  Widget _topbar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new,
                  size: 14,
                  color: Color(0xFF444444),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Perangkat',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111111),
              ),
            ),
          ],
        ),
        _addButton(height: 32),
      ],
    ),
  );

  Widget _addButton({required double height, bool large = false}) =>
      GestureDetector(
        onTap: _addDevice,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: large ? 20 : 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F766E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: large ? 14 : 16, color: Colors.white),
              const SizedBox(width: 5),
              const Text(
                'Tambah Perangkat',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );

  // ── Search ──
  Widget _searchBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5)),
    ),
    child: Container(
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 11, color: Color(0xFF111111)),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          prefixIcon: Icon(Icons.search, size: 16, color: Color(0xFFBBBBBB)),
          prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 34),
          hintText: 'Cari perangkat...',
          hintStyle: TextStyle(fontSize: 11, color: Color(0xFFCCCCCC)),
          contentPadding: EdgeInsets.symmetric(vertical: 9),
        ),
      ),
    ),
  );

  // ── State kosong ──
  Widget _emptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(
            Icons.print_outlined,
            size: 28,
            color: Color(0xFFBBBBBB),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Belum ada perangkat',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Color(0xFF111111),
          ),
        ),
        const SizedBox(height: 12),
        // Dulu menyebut "barcode scanner", padahal wizard hanya menawarkan
        // Printer Kasir & Printer Dapur — menjanjikan yang tak bisa dipilih.
        const Text(
          'Tambah printer kasir atau printer dapur\nuntuk mulai mencetak',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB), height: 1.6),
        ),
        const SizedBox(height: 12),
        _addButton(height: 36, large: true),
      ],
    ),
  );

  // ── List (grouped) ──
  Widget _list() {
    const printerJenis = {'kasir', 'dapur', 'label', 'alamat', 'terpusat'};
    final printers = _filtered
        .where((d) => printerJenis.contains(d.jenis))
        .toList();
    final scanners = _filtered.where((d) => d.jenis == 'scanner').toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (printers.isNotEmpty) ...[
            _sectionLabel('Printer (${printers.length})', top: false),
            for (final d in printers) ...[
              _deviceCard(d),
              const SizedBox(height: 8),
            ],
          ],
          if (scanners.isNotEmpty) ...[
            _sectionLabel(
              'Scanner (${scanners.length})',
              top: printers.isNotEmpty,
            ),
            for (final d in scanners) ...[
              _deviceCard(d),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String t, {bool top = true}) => Padding(
    padding: EdgeInsets.fromLTRB(2, top ? 4 : 0, 2, 4),
    child: Text(
      t.toUpperCase(),
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: Color(0xFFBBBBBB),
        letterSpacing: 0.5,
      ),
    ),
  );

  Widget _deviceCard(SavedPrinter d) {
    final connected = _isConnected(d);
    final isDefault = _defaultPrinterId == d.id;
    final detailId = d.isLan
        ? '${d.host}:${d.port}'
        : (d.mac.isEmpty ? '-' : d.mac);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEFEFEF), width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Info (tap → konfigurasi)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openConfig(d),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF111111),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isDefault) ...[
                        _defaultBadge(),
                        const SizedBox(width: 4),
                      ],
                      _statusBadge(connected),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${printerRoleLabel(d)} · ${_connLabels[d.type] ?? d.type} · $detailId',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Aksi
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (connected)
                _actionBtn(
                  d.jenis == 'scanner' ? 'Test Scan' : 'Test Print',
                  bg: const Color(0xFFF5F5F5),
                  fg: const Color(0xFF666666),
                  onTap: () => _testPrint(d),
                )
              else
                _actionBtn(
                  'Hubungkan',
                  bg: const Color(0xFF1D9E75),
                  fg: Colors.white,
                  onTap: () => _connect(d),
                ),
              const SizedBox(width: 6),
              _actionBtn(
                'Hapus',
                bg: Colors.white,
                fg: const Color(0xFF0F766E),
                border: const Color(0xFFFCCACA),
                onTap: () => _confirmDelete(d),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(bool connected) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: connected ? const Color(0xFFEAF3DE) : const Color(0xFFF0F0F0),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      connected ? '● Terhubung' : '● Terputus',
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: connected ? const Color(0xFF27500A) : const Color(0xFF888888),
      ),
    ),
  );

  Widget _defaultBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF3CD),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Text(
      'Default',
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: Color(0xFF7A5B00),
      ),
    ),
  );

  Widget _actionBtn(
    String label, {
    required Color bg,
    required Color fg,
    Color? border,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: border != null ? Border.all(color: border, width: 1.5) : null,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    ),
  );

  // ── Aksi handler ──
  Future<void> _testPrint(SavedPrinter d) async {
    if (d.jenis == 'scanner') {
      _snack('Tes scanner belum didukung');
      return;
    }
    final bytes = await KitchenTicketBuilder(
      paperSize: d.paper == '80' ? PaperSize.mm80 : PaperSize.mm58,
      driver: d.driver,
    ).buildTest(d.name);
    final ok = await _printer.testPrintTo(d, bytes);
    _snack(
      ok ? 'Tes terkirim ke ${d.name}' : 'Gagal mencetak ke ${d.name}',
      error: !ok,
    );
  }

  Future<void> _connect(SavedPrinter d) async {
    _snack('Menghubungkan ${d.name}...');
    final ok = await _printer.connectPrinter(d);
    if (!mounted) return;
    setState(() => _connectedMac = _printer.connectedDevice?.address);
    _snack(
      ok ? '${d.name} terhubung' : 'Gagal menghubungkan ${d.name}',
      error: !ok,
    );
  }

  Future<void> _confirmDelete(SavedPrinter d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Hapus Perangkat?'),
        content: Text(
          'Perangkat ${d.name} akan dihapus dan perlu disambungkan ulang.',
          style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Batal',
              style: TextStyle(color: Color(0xFF555555)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Hapus',
              style: TextStyle(
                color: Color(0xFF0F766E),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _printer.removePrinter(d.id);
    await _load();
  }
}

// ── Halaman scan Bluetooth ala Majoo (kiri: Tipe Driver, kanan: daftar device) ──
class _BtScanPage extends StatefulWidget {
  final String title;
  const _BtScanPage({required this.title});
  @override
  State<_BtScanPage> createState() => _BtScanPageState();
}

class _BtScanPageState extends State<_BtScanPage> {
  final _printer = PrinterService();
  // Kumulatif: device ditambahkan saat stream memancarkan hasil, di-dedup
  // berdasarkan MAC sehingga tidak hilang saat stream re-emit subset.
  final Map<String, BluetoothDevice> _deviceMap = {};
  bool _scanning = false;
  String? _selectedMac;
  StreamSubscription? _sub;

  List<BluetoothDevice> get _devices => _deviceMap.values.toList();

  @override
  void initState() {
    super.initState();
    _printer.init();
    // Dengarkan stream scan — setiap batch yang masuk di-merge ke map.
    _sub = _printer.scanResultsStream.listen((batch) {
      if (!mounted) return;
      setState(() {
        for (final d in batch) {
          _deviceMap[d.address] = d;
        }
      });
    });
    _startScan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_scanning) _printer.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    // Pastikan Bluetooth menyala — tampilkan prompt & tunggu user mengaktifkan.
    final btOn = await _printer.ensureBluetoothOn();
    if (!btOn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bluetooth belum aktif. Aktifkan untuk mencetak.'),
          ),
        );
      }
      return;
    }

    // Bersihkan hasil scan sebelumnya saat user menekan Scan ulang.
    setState(() {
      _deviceMap.clear();
      _scanning = true;
    });
    try {
      // `scan()` blocking — sementara berjalan, stream listener di atas
      // sudah mengumpulkan device ke _deviceMap. Hasil akhir di-merge juga.
      final d = await _printer.scan();
      if (mounted) {
        setState(() {
          for (final dev in d) {
            _deviceMap[dev.address] = dev;
          }
        });
      }
    } on PrinterPermissionException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Izin Bluetooth ditolak')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _confirm() {
    final m = _deviceMap[_selectedMac];
    if (m == null) return;
    Navigator.pop(context, (name: m.name, mac: m.address));
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111111),
        elevation: 0.5,
        title: Text('${widget.title} - Bluetooth'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: _teal),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              onPressed: _scanning ? null : _startScan,
              style: FilledButton.styleFrom(backgroundColor: _teal),
              child: Text(_scanning ? 'Scanning...' : 'Scan'),
            ),
          ),
        ],
      ),
      // Dulu di sini ada kolom kiri selebar 260px berisi "Tipe Driver: Generic 1".
      // Dua alasan ia dibuang: (1) itu InputDecorator statis, bukan dropdown —
      // tak ada pilihan lain dan field `driver` tak pernah dibaca siapa pun;
      // (2) di layar HP (±360dp) ia menyisakan ~100dp untuk daftar perangkat,
      // sehingga nama & MAC printer terpotong. Protokol yang sebenarnya dipakai
      // sudah jujur tertulis di tab Tipe: "ESC/POS (thermal generik)".
      body: _scanning && devices.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: _teal),
                  SizedBox(height: 16),
                  Text(
                    'Mencari perangkat Bluetooth...',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),
                ],
              ),
            )
          : devices.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bluetooth_disabled, size: 48, color: _muted),
                  const SizedBox(height: 12),
                  const Text(
                    'Tidak ada perangkat ditemukan',
                    style: TextStyle(fontSize: 13, color: _muted),
                  ),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Pastikan printer menyala dan sudah di-pair lewat '
                      'pengaturan Bluetooth HP.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: _muted,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _startScan,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Scan Ulang'),
                    style: FilledButton.styleFrom(backgroundColor: _teal),
                  ),
                ],
              ),
            )
          : RadioGroup<String>(
              groupValue: _selectedMac,
              onChanged: (v) => setState(() => _selectedMac = v),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      children: [
                        Row(
                          children: [
                            const Text(
                              'NAMA',
                              style: TextStyle(fontSize: 12, color: _muted),
                            ),
                            const Spacer(),
                            Text(
                              '${devices.length} perangkat',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final d in devices)
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            activeColor: _teal,
                            value: d.address,
                            title: Text(d.name.isEmpty ? 'Unknown' : d.name),
                            subtitle: Text(
                              d.address,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Tombol dijangkarkan di bawah, bukan ikut menggulung:
                  // dengan banyak device, "Pilih Perangkat" dulu terdorong
                  // ke luar layar dan user mengira scan-nya menggantung.
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton(
                          onPressed: _selectedMac == null ? null : _confirm,
                          style: FilledButton.styleFrom(backgroundColor: _teal),
                          child: const Text('Pilih Perangkat'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ── Konfigurasi perangkat ala Majoo (2 kolom) ──
class DeviceConfigPage extends StatefulWidget {
  final SavedPrinter printer;
  final String outletId;
  const DeviceConfigPage({
    super.key,
    required this.printer,
    required this.outletId,
  });
  @override
  State<DeviceConfigPage> createState() => _DeviceConfigPageState();
}

class _DeviceConfigPageState extends State<DeviceConfigPage> {
  final _printer = PrinterService();
  late SavedPrinter _p;
  List<PrintStation> _stations = const [];
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  bool _isDefault = false;
  PrinterHealth? _health;
  bool _checkingHealth = false;
  bool _saving = false;
  // Jeda antar-cetak (detik) — setelan device global, bukan per-printer. Dipakai
  // agar struk kasir & tiket dapur dari 1 printer tidak keluar berdempet.
  int _printGapSec = 0;

  @override
  void initState() {
    super.initState();
    _p = widget.printer;
    _nameCtrl = TextEditingController(text: _p.name);
    _hostCtrl = TextEditingController(text: _p.host);
    _portCtrl = TextEditingController(text: '${_p.port}');
    _loadDefault();
    _loadStations();
    _loadPrintGap();
  }

  Future<void> _loadPrintGap() async {
    final ms = await _printer.printGapMs();
    if (mounted) setState(() => _printGapSec = (ms / 1000).round());
  }

  Future<void> _loadDefault() async {
    final id = await _printer.defaultPrinterId();
    if (mounted) setState(() => _isDefault = id == _p.id);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStations() async {
    if (widget.outletId.isEmpty) return;
    try {
      final row = await Supabase.instance.client
          .from('outlets')
          .select('settings')
          .eq('id', widget.outletId)
          .single();
      final settings = (row['settings'] as Map?)?.cast<String, dynamic>();
      final config = PrintStationConfig.fromSettings(settings);
      if (!mounted) return;
      setState(() => _stations = config.stations);
    } catch (_) {
      // Mapping kategori lokal tetap tersedia bila setting outlet belum termuat.
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Nama perangkat wajib diisi', error: true);
      return;
    }
    final port = int.tryParse(_portCtrl.text.trim()) ?? 0;
    if (_p.isLan && !isValidIpv4(_hostCtrl.text.trim())) {
      _snack('Alamat IP tidak valid', error: true);
      return;
    }
    if (_p.isLan && (port < 1 || port > 65535)) {
      _snack('Port harus antara 1–65535', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      _p = _p.copyWith(
        name: name,
        host: _p.isLan ? _hostCtrl.text.trim() : _p.host,
        port: _p.isLan ? port : _p.port,
      );
      // Multi-peran ala Majoo: toggle Struk & Dapur independen. `jenis` legacy
      // di-derive untuk kompatibilitas, sedangkan daftar menampilkan peran
      // sebenarnya dari kedua toggle ini.
      final jenis = _p.dapurEnabled && !_p.strukEnabled ? 'dapur' : 'kasir';
      _p = _p.copyWith(
        jenis: jenis,
        enabled: _p.strukEnabled || _p.dapurEnabled,
      );
      await _printer.savePrinter(_p);

      // Jangan pernah menampilkan pesan sukses hanya karena proses tulis tidak
      // melempar error. Pastikan data yang sama benar-benar dapat dibaca lagi.
      final persisted = await _printer.listPrinters();
      if (!persisted.any((printer) => printer.id == _p.id)) {
        throw StateError('Perangkat tidak ditemukan setelah disimpan');
      }

      if (_isDefault) {
        await _printer.setDefaultPrinter(_p.id);
      } else if (await _printer.defaultPrinterId() == _p.id) {
        await _printer.setDefaultPrinter(null);
      }
      if (!mounted) return;
      Navigator.pop(context, _p);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(
        'Perangkat belum berhasil disimpan. Silakan coba kembali.',
        error: true,
      );
    }
  }

  Future<void> _delete() async {
    await _printer.removePrinter(_p.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _testPrint() async {
    final bytes = await KitchenTicketBuilder(
      paperSize: _p.paper == '80' ? PaperSize.mm80 : PaperSize.mm58,
      driver: _p.driver,
    ).buildTest(_p.name);
    final ok = await _printer.testPrintTo(_p, bytes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Tes terkirim' : 'Gagal mencetak')),
    );
  }

  Future<void> _checkHealth() async {
    setState(() => _checkingHealth = true);
    final result = await _printer.checkHealth(_p);
    if (!mounted) return;
    setState(() {
      _health = result;
      _checkingHealth = false;
    });
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? const Color(0xFF991B1B)
            : const Color(0xFF111111),
      ),
    );
  }

  Future<void> _aturKategori() async {
    final res = await Navigator.of(context)
        .push<({List<String> cats, String mode, String name})>(
          MaterialPageRoute(
            builder: (_) => _AturKategoriPage(
              outletId: widget.outletId,
              name: _p.headerLabel.isNotEmpty ? _p.headerLabel : _p.name,
              selected: _p.categories,
              printMode: _p.printMode,
            ),
          ),
        );
    if (res == null) return;
    final updated = _p.copyWith(
      categories: res.cats,
      printMode: res.mode,
      headerLabel: res.name,
    );
    setState(() => _p = updated);
    try {
      // Tombol Simpan di halaman Atur Kategori harus langsung persisten.
      // Sebelumnya pengguna masih wajib menekan Simpan kedua di halaman
      // printer; bila langsung mengetes, mode lama tetap dipakai sehingga
      // pilihan Pisah terlihat seperti Gabung.
      await _printer.updatePrinter(
        _p.id,
        categories: res.cats,
        printMode: res.mode,
        headerLabel: res.name,
      );
      final persisted = (await _printer.listPrinters()).where(
        (printer) => printer.id == _p.id,
      );
      if (persisted.isEmpty) {
        throw StateError('Printer tidak ditemukan setelah disimpan');
      }
      final saved = persisted.first;
      final savedCategories = saved.categories.toSet();
      final requestedCategories = res.cats.toSet();
      if (saved.printMode != res.mode ||
          saved.headerLabel != res.name ||
          savedCategories.length != requestedCategories.length ||
          !savedCategories.containsAll(requestedCategories)) {
        throw StateError('Pengaturan kategori belum tersimpan');
      }
      _snack(
        res.mode == 'pisah'
            ? 'Mode Pisah tersimpan: satu tiket per kategori'
            : 'Mode Gabung tersimpan: semua kategori satu tiket',
      );
    } catch (_) {
      _snack(
        'Pengaturan kategori belum berhasil disimpan. Silakan coba kembali.',
        error: true,
      );
    }
  }

  void _setStationSelected(String stationId, bool selected) {
    final ids = _p.effectiveStationIds.toSet();
    if (selected) {
      ids.add(stationId);
    } else {
      ids.remove(stationId);
    }
    // Urutan pilihan mengikuti Owner Panel agar urutan tiket yang keluar dari
    // printer fisik ini selalu konsisten.
    final orderedIds = _stations
        .where((station) => ids.contains(station.id))
        .map((station) => station.id)
        .toList();
    setState(
      () => _p = _p.copyWith(
        stationIds: orderedIds,
        // Field tunggal lama tetap diisi agar versi aplikasi terdahulu masih
        // dapat membaca setidaknya stasiun pertama.
        stationId: orderedIds.isEmpty ? '' : orderedIds.first,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF111111),
          elevation: 0.5,
          title: Text(_p.name.isEmpty ? 'Printer' : _p.name),
          actions: [
            PopupMenuButton<String>(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: const [
                    Text('Aksi', style: TextStyle(color: _teal)),
                    Icon(Icons.arrow_drop_down, color: _teal),
                  ],
                ),
              ),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'test', child: Text('Tes Cetak')),
                const PopupMenuItem(
                  value: 'health',
                  child: Text('Cek Koneksi'),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Hapus Perangkat'),
                ),
              ],
              onSelected: (v) {
                if (v == 'test') _testPrint();
                if (v == 'health') _checkHealth();
                if (v == 'delete') _delete();
              },
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: _teal),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Simpan'),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: _teal,
            unselectedLabelColor: Color(0xFF888888),
            indicatorColor: _teal,
            labelStyle: TextStyle(fontWeight: FontWeight.w700),
            tabs: [
              Tab(text: 'Tipe'),
              Tab(text: 'Struk'),
              Tab(text: 'Dapur'),
            ],
          ),
        ),
        body: TabBarView(children: [_tipeTab(), _strukTab(), _dapurTab()]),
      ),
    );
  }

  Widget _tipeTab() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      TextField(
        controller: _nameCtrl,
        decoration: const InputDecoration(labelText: 'Nama Perangkat'),
      ),
      const SizedBox(height: 20),
      const Text('Tipe Kertas', style: TextStyle(fontSize: 12, color: _muted)),
      DropdownButton<String>(
        value: _p.paper,
        isExpanded: true,
        underline: Container(height: 1, color: const Color(0xFFE0E0E0)),
        items: const [
          DropdownMenuItem(value: '58', child: Text('58mm')),
          DropdownMenuItem(value: '80', child: Text('80mm')),
        ],
        onChanged: (v) => setState(() => _p = _p.copyWith(paper: v)),
      ),
      const SizedBox(height: 20),
      const Text('Tipe Driver', style: TextStyle(fontSize: 12, color: _muted)),
      DropdownButton<String>(
        value: const {'generic1', 'generic2', 'compact'}.contains(_p.driver)
            ? _p.driver
            : 'generic1',
        isExpanded: true,
        underline: Container(height: 1, color: const Color(0xFFE0E0E0)),
        items: const [
          DropdownMenuItem(
            value: 'generic1',
            child: Text('Generic 1 — ESC/POS standar'),
          ),
          DropdownMenuItem(
            value: 'generic2',
            child: Text('Generic 2 — kompatibilitas alternatif'),
          ),
          DropdownMenuItem(
            value: 'compact',
            child: Text('Compact — printer thermal kecil'),
          ),
        ],
        onChanged: (v) => setState(() => _p = _p.copyWith(driver: v)),
      ),
      if (_p.isLan) ...[
        const SizedBox(height: 20),
        const Text(
          'Koneksi LAN',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        TextField(
          controller: _hostCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Alamat IP'),
        ),
        TextField(
          controller: _portCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Port'),
        ),
      ] else ...[
        const SizedBox(height: 20),
        const Text(
          'Alamat Bluetooth',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _p.mac,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
      const SizedBox(height: 20),
      const Text('Protokol', style: TextStyle(fontSize: 12, color: _muted)),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'ESC/POS (thermal generik)',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: _teal,
        title: const Text('Jadikan printer struk default'),
        subtitle: const Text(
          'Printer ini dipakai sebagai tujuan utama cetak struk.',
          style: TextStyle(fontSize: 11, color: _muted),
        ),
        value: _isDefault,
        onChanged: _p.strukEnabled
            ? (v) => setState(() => _isDefault = v)
            : null,
      ),
      if (_health != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${_health!.message}${_health!.latencyMs == null ? '' : ' · ${_health!.latencyMs} ms'}',
            style: TextStyle(
              fontSize: 12,
              color: _health!.ok ? const Color(0xFF27500A) : _teal,
            ),
          ),
        ),
      OutlinedButton.icon(
        onPressed: _checkingHealth ? null : _checkHealth,
        icon: _checkingHealth
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.network_check, size: 17),
        label: const Text('Cek Koneksi'),
      ),
    ],
  );

  Widget _strukTab() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      _switch(
        'Aktifkan Struk',
        _p.strukEnabled,
        (v) => setState(() => _p = _p.copyWith(strukEnabled: v)),
        subtitle: 'Printer ini mencetak struk pelanggan.',
      ),
      // Label dulu cuma "Autoprint Bayar" — persis sama dengan toggle di tab
      // Dapur, padahal yang satu mencetak STRUK dan satunya TIKET DAPUR.
      _switch(
        'Cetak struk otomatis saat order QR masuk',
        _p.strukAutoOrder,
        (v) => setState(() => _p = _p.copyWith(strukAutoOrder: v)),
        subtitle: _p.strukAutoOrder
            ? 'Struk bertanda belum dibayar keluar saat pesanan QR diterima.'
            : 'Pesanan QR tetap masuk ke daftar tanpa mencetak struk pelanggan.',
      ),
      _switch(
        'Cetak struk otomatis saat bayar',
        _p.strukAutoBayar,
        (v) => setState(() => _p = _p.copyWith(strukAutoBayar: v)),
        subtitle: _p.strukAutoBayar
            ? 'Struk keluar sendiri begitu pembayaran selesai.'
            : 'Struk hanya keluar bila dicetak manual dari Daftar Order.',
      ),
      const SizedBox(height: 8),
      _copiesRow(
        value: _p.copies,
        onChanged: (n) => setState(() => _p = _p.copyWith(copies: n)),
      ),
    ],
  );

  Widget _dapurTab() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      if (_stations.isNotEmpty) ...[
        const Text(
          'Stasiun Outlet yang Dilayani',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 6),
          child: Text(
            'Centang satu atau beberapa stasiun. Setiap stasiun dicetak sebagai tiket terpisah pada printer ini.',
            style: TextStyle(fontSize: 11, color: _muted, height: 1.4),
          ),
        ),
        for (final station in _stations)
          CheckboxListTile(
            key: ValueKey('printer-station-${station.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: _teal,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(station.name),
            value: _p.effectiveStationIds.contains(station.id),
            onChanged: (selected) =>
                _setStationSelected(station.id, selected ?? false),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 12),
          child: Text(
            'Jika tidak ada stasiun yang dicentang, printer memakai pengaturan kategori lokal di bawah.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
        ),
      ],
      _switch(
        'Aktifkan Dapur',
        _p.dapurEnabled,
        (v) => setState(() => _p = _p.copyWith(dapurEnabled: v)),
        subtitle: 'Printer ini mencetak tiket dapur.',
      ),
      _switch(
        'Cetak tiket saat order dikirim',
        _p.autoOrder,
        (v) => setState(() => _p = _p.copyWith(autoOrder: v)),
        subtitle: 'Untuk order yang dibuat dan dikirim dari kasir ini.',
      ),
      _switch(
        'Autoprint Pesanan QR',
        _p.autoQrOrder,
        (v) => setState(() => _p = _p.copyWith(autoQrOrder: v)),
        subtitle: _p.autoQrOrder
            ? 'Tiket dapur otomatis dicetak saat pesanan QR masuk. Aktifkan hanya pada satu kasir utama.'
            : 'Pesanan QR tetap masuk tanpa mencetak tiket dapur dari perangkat ini.',
      ),
      _switch(
        'Cetak tiket saat pembayaran',
        _p.autoBayar,
        (v) => setState(() => _p = _p.copyWith(autoBayar: v)),
      ),
      _switch(
        'Cetak tiket saat void',
        _p.autoVoid,
        (v) => setState(() => _p = _p.copyWith(autoVoid: v)),
      ),
      const SizedBox(height: 8),
      // Salinan tiket dapur memakai `copies` (perilaku versi sebelumnya).
      _copiesRow(
        value: _p.copies,
        onChanged: (n) => setState(() => _p = _p.copyWith(copies: n)),
      ),
      const SizedBox(height: 4),
      _gapRow(),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _p.effectiveStationIds.isEmpty ? _aturKategori : null,
        icon: const Icon(Icons.settings, size: 18),
        label: Text(
          _p.effectiveStationIds.isNotEmpty
              ? 'Kategori mengikuti ${_p.effectiveStationIds.length} stasiun terpilih'
              : 'Atur Kategori (${_p.categories.isEmpty ? 'semua' : _p.categories.length} • ${_p.printMode})',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF111111),
          minimumSize: const Size.fromHeight(48),
        ),
      ),
    ],
  );

  Widget _copiesRow({
    required int value,
    required ValueChanged<int> onChanged,
  }) => Row(
    children: [
      const Expanded(child: Text('Jumlah Salinan')),
      IconButton(
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: value > 1 ? () => onChanged(value - 1) : null,
      ),
      Text('$value', style: const TextStyle(fontWeight: FontWeight.w600)),
      IconButton(
        icon: const Icon(Icons.add_circle_outline),
        onPressed: value < 5 ? () => onChanged(value + 1) : null,
      ),
    ],
  );

  // Jeda antar-cetak (device global). Nilai 0 = tanpa jeda. Disimpan langsung
  // ke PrinterService agar berlaku untuk semua printer/alur cetak.
  Widget _gapRow() {
    Future<void> set(int sec) async {
      final v = sec.clamp(0, 10);
      await _printer.setPrintGapMs(v * 1000);
      if (mounted) setState(() => _printGapSec = v);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Jeda sebelum tiket dapur')),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: _printGapSec > 0 ? () => set(_printGapSec - 1) : null,
            ),
            Text(
              _printGapSec == 0 ? 'Off' : '${_printGapSec}s',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _printGapSec < 10 ? () => set(_printGapSec + 1) : null,
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(left: 2, right: 48),
          child: Text(
            'Jarak waktu antara struk kasir dan tiket dapur dari 1 printer, '
            'agar tidak keluar berdempet (bisa disobek dulu).',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
        ),
      ],
    );
  }

  Widget _switch(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    activeThumbColor: _teal,
    title: Text(title),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: _muted, height: 1.4),
          ),
    value: value,
    onChanged: onChanged,
  );
}

// ── Atur Kategori ala Majoo (kiri: Nama + Pisah/Gabung, kanan: kategori) ──
class _AturKategoriPage extends StatefulWidget {
  final String outletId;
  final String name;
  final List<String> selected;
  final String printMode;
  const _AturKategoriPage({
    required this.outletId,
    required this.name,
    required this.selected,
    required this.printMode,
  });
  @override
  State<_AturKategoriPage> createState() => _AturKategoriPageState();
}

class _AturKategoriPageState extends State<_AturKategoriPage> {
  List<Map<String, dynamic>> _cats = const [];
  late Set<String> _selected;
  late String _mode;
  late final TextEditingController _nameCtrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected.toSet();
    _mode = widget.printMode;
    _nameCtrl = TextEditingController(text: widget.name);
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('menu_categories')
          .select('id, name')
          .eq('outlet_id', widget.outletId)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        _cats = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _allSelected => _selected.isEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111111),
        elevation: 0.5,
        title: const Text('Atur Kategori'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _teal),
              onPressed: () => Navigator.pop(context, (
                cats: _selected.toList(),
                mode: _mode,
                name: _nameCtrl.text.trim(),
              )),
              child: const Text('Simpan'),
            ),
          ),
        ],
      ),
      // Dua kolom hanya bila layarnya memang muat (tablet). Di HP, kolom kiri
      // tetap 280px menyisakan ~80dp untuk daftar kategori — nama kategori jadi
      // terpotong sampai tak terbaca. Di bawah 600dp keduanya ditumpuk vertikal.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, c) => c.maxWidth >= 600
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 280, child: _pengaturanPanel()),
                        const VerticalDivider(width: 1),
                        Expanded(child: _kategoriList()),
                      ],
                    )
                  : Column(
                      children: [
                        _pengaturanPanel(),
                        const Divider(height: 1),
                        Expanded(child: _kategoriList()),
                      ],
                    ),
            ),
    );
  }

  Widget _pengaturanPanel() => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Nama Dapur', style: TextStyle(fontSize: 12, color: _muted)),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'mis. Dapur - Bar',
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Print Kategori',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final m in const ['pisah', 'gabung'])
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _mode = m),
                  child: Container(
                    margin: EdgeInsets.only(right: m == 'pisah' ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _mode == m ? _teal : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _mode == m ? _teal : const Color(0xFFD0D0D0),
                      ),
                    ),
                    child: Text(
                      m == 'pisah' ? 'Pisah' : 'Gabung',
                      style: TextStyle(
                        color: _mode == m
                            ? Colors.white
                            : const Color(0xFF555555),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _mode == 'pisah'
              ? 'Satu tiket terpisah untuk tiap kategori.'
              : 'Semua kategori digabung dalam satu tiket.',
          style: const TextStyle(fontSize: 10, color: _muted, height: 1.4),
        ),
      ],
    ),
  );

  Widget _kategoriList() {
    if (_cats.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Belum ada kategori menu di outlet ini.\nTiket dapur akan memuat semua item.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          activeColor: _teal,
          title: const Text('Semua Kategori'),
          value: _allSelected,
          onChanged: (v) {
            if (v == true) setState(() => _selected.clear());
          },
        ),
        for (final c in _cats)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: _teal,
            title: Text(c['name'] as String? ?? '-'),
            value: _selected.contains(c['id']),
            onChanged: (v) => setState(() {
              final id = c['id'] as String;
              if (v == true) {
                _selected.add(id);
              } else {
                _selected.remove(id);
              }
            }),
          ),
      ],
    );
  }
}

// ── Dialog "Pilih Jenis Perangkat" (kustom, sesuai spesifikasi desain) ────────
// Mengembalikan key jenis ('kasir'|'dapur'|'label'|'alamat'|'terpusat'|'scanner')
// via Navigator.pop, atau null bila dibatalkan. Tidak mengubah logika perangkat.
Future<String?> _pickJenisPerangkat(BuildContext context) => _showOptionPicker(
  context,
  title: 'Pilih Jenis Perangkat',
  subtitle: 'Pilih satu jenis perangkat',
  confirmLabel: 'Pilih Perangkat',
  options: const [
    _OptItem('kasir', 'Printer Kasir', 'Cetak struk transaksi'),
    _OptItem('dapur', 'Printer Dapur', 'Cetak tiket order dapur'),
  ],
);

// Opsi 'usb' dihapus: memilihnya selalu berakhir "belum didukung" SETELAH user
// menjawab dua dialog. Menawarkan pilihan yang pasti gagal bukan fitur.
// Kembalikan ke sini bila _addDevice benar-benar bisa menanganinya.
Future<String?> _pickKoneksi(BuildContext context) => _showOptionPicker(
  context,
  title: 'Koneksi Melalui',
  subtitle: 'Pilih cara perangkat tersambung',
  confirmLabel: 'Lanjut',
  options: const [
    _OptItem('bt', 'Bluetooth', 'Printer thermal via Bluetooth'),
    _OptItem('lan', 'WiFi / LAN', 'Printer jaringan (alamat IP)'),
  ],
);

// ── Picker opsi kustom (dipakai dialog jenis & koneksi) ───────────────────────
Future<String?> _showOptionPicker(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String confirmLabel,
  required List<_OptItem> options,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierLabel: title,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => _OptionPickerDialog(
      title: title,
      subtitle: subtitle,
      confirmLabel: confirmLabel,
      options: options,
    ),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _OptItem {
  final String key;
  final String name;
  final String subtitle;
  const _OptItem(this.key, this.name, this.subtitle);
}

class _OptionPickerDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final String confirmLabel;
  final List<_OptItem> options;
  const _OptionPickerDialog({
    required this.title,
    required this.subtitle,
    required this.confirmLabel,
    required this.options,
  });
  @override
  State<_OptionPickerDialog> createState() => _OptionPickerDialogState();
}

class _OptionPickerDialogState extends State<_OptionPickerDialog> {
  static const _kInk = Color(0xFF111111);
  static const _kRed = Color(0xFF0F766E);
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.of(context).size.width - 48).clamp(0.0, 340.0);
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            Flexible(child: SingleChildScrollView(child: _body())),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _kInk,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                widget.subtitle,
                style: const TextStyle(fontSize: 10, color: Color(0xFF999999)),
              ),
            ),
          ],
        ),
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.close, size: 12, color: Color(0xFF888888)),
          ),
        ),
      ],
    ),
  );

  Widget _body() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Column(
      children: [
        for (var i = 0; i < widget.options.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _optionItem(widget.options[i]),
        ],
      ],
    ),
  );

  Widget _optionItem(_OptItem o) {
    final active = _selected == o.key;
    return GestureDetector(
      onTap: () => setState(() => _selected = o.key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFFF5F5) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? _kRed : const Color(0xFFEFEFEF),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _kInk,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      o.subtitle,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF999999),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? _kRed : const Color(0xFFD0D0D0),
                  width: 2,
                ),
              ),
              child: active
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kRed,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final enabled = _selected != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0F0F0), width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFE0E0E0),
                    width: 1.5,
                  ),
                ),
                child: const Text(
                  'Batal',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF555555),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: enabled ? () => Navigator.pop(context, _selected) : null,
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: enabled ? _kRed : const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.confirmLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

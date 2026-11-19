import 'dart:async';
import 'package:bluetooth_print_plus/bluetooth_print_plus.dart' hide Alignment;
import 'package:flutter/material.dart';
import '../services/printer_service.dart';

// Warna brand (konsisten dgn device_settings_page.dart)
const _kRed = Color(0xFF0F766E);
const _kMuted = Color(0xFF94A3B8);
const _kInk = Color(0xFF111111);
const _kGreen = Color(0xFF1D9E75);

/// Tampilkan dialog untuk menghubungkan printer Bluetooth sebelum mencetak.
///
/// Mengembalikan `true` jika printer berhasil terhubung, `false` jika user
/// memilih "Lewati" atau menutup dialog. Popup ini dipakai saat transaksi
/// selesai tapi printer belum terhubung — user bisa connect atau skip.
Future<bool> showPrinterConnectDialog(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _PrinterConnectSheet(),
  );
  return result ?? false;
}

class _PrinterConnectSheet extends StatefulWidget {
  const _PrinterConnectSheet();
  @override
  State<_PrinterConnectSheet> createState() => _PrinterConnectSheetState();
}

class _PrinterConnectSheetState extends State<_PrinterConnectSheet> {
  final _printer = PrinterService();
  final Map<String, BluetoothDevice> _deviceMap = {};
  bool _scanning = false;
  bool _connecting = false;
  String? _selectedMac;
  String? _connectingMac;
  StreamSubscription? _scanSub;

  List<BluetoothDevice> get _devices => _deviceMap.values.toList();

  @override
  void initState() {
    super.initState();
    _printer.init();

    // Jika printer sudah terhubung, langsung tutup → return true.
    if (_printer.isConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
      return;
    }

    // Dengarkan stream scan — kumulatif, dedup by MAC.
    _scanSub = _printer.scanResultsStream.listen((batch) {
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
    _scanSub?.cancel();
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

    setState(() {
      _deviceMap.clear();
      _scanning = true;
    });
    try {
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

  Future<void> _connectDevice() async {
    if (_selectedMac == null) return;
    final device = _deviceMap[_selectedMac];
    if (device == null) return;

    setState(() {
      _connecting = true;
      _connectingMac = _selectedMac;
    });

    final ok = await _printer.connect(device);

    if (!mounted) return;
    if (ok) {
      // Simpan sebagai printer terakhir — otomatis oleh PrinterService.connect.
      Navigator.pop(context, true);
    } else {
      setState(() {
        _connecting = false;
        _connectingMac = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menghubungkan ${device.name}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final maxH = MediaQuery.of(context).size.height * 0.65;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Handle ──
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD0D0D0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Header ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kRed.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.print_outlined,
                    size: 22,
                    color: _kRed,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Printer Belum Terhubung',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _kInk,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Hubungkan printer untuk mencetak struk',
                        style: TextStyle(fontSize: 12, color: _kMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),

          // ── Device list ──
          Flexible(
            child: _scanning && devices.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: _kRed),
                        SizedBox(height: 16),
                        Text(
                          'Mencari perangkat Bluetooth...',
                          style: TextStyle(fontSize: 12, color: _kMuted),
                        ),
                      ],
                    ),
                  )
                : devices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.bluetooth_disabled,
                          size: 40,
                          color: _kMuted,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Tidak ada perangkat ditemukan',
                          style: TextStyle(fontSize: 12, color: _kMuted),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _startScan,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Scan Ulang'),
                          style: TextButton.styleFrom(foregroundColor: _kRed),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: devices.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 60),
                    itemBuilder: (_, i) {
                      final d = devices[i];
                      final selected = _selectedMac == d.address;
                      final isConnecting =
                          _connecting && _connectingMac == d.address;
                      // The sheet has a decorated container; give each
                      // tile its own Material so Android ink/highlights
                      // are not hidden by that decoration.
                      return Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected
                                  ? _kRed.withValues(alpha: 0.1)
                                  : const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.bluetooth,
                              size: 20,
                              color: selected ? _kRed : _kMuted,
                            ),
                          ),
                          title: Text(
                            d.name.isEmpty ? 'Unknown Device' : d.name,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: _kInk,
                            ),
                          ),
                          subtitle: Text(
                            d.address,
                            style: const TextStyle(
                              fontSize: 11,
                              color: _kMuted,
                            ),
                          ),
                          trailing: isConnecting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _kRed,
                                  ),
                                )
                              : selected
                              ? const Icon(
                                  Icons.check_circle,
                                  color: _kRed,
                                  size: 22,
                                )
                              : const Icon(
                                  Icons.circle_outlined,
                                  color: Color(0xFFD0D0D0),
                                  size: 22,
                                ),
                          onTap: _connecting
                              ? null
                              : () => setState(() => _selectedMac = d.address),
                        ),
                      );
                    },
                  ),
          ),

          // ── Scan ulang + info ──
          if (devices.isNotEmpty || _scanning)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  if (_scanning)
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _kRed,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Scanning...',
                          style: TextStyle(fontSize: 11, color: _kMuted),
                        ),
                      ],
                    )
                  else
                    Text(
                      '${devices.length} perangkat ditemukan',
                      style: const TextStyle(fontSize: 11, color: _kMuted),
                    ),
                  const Spacer(),
                  if (!_scanning)
                    TextButton.icon(
                      onPressed: _startScan,
                      icon: const Icon(Icons.refresh, size: 14),
                      label: const Text(
                        'Scan Ulang',
                        style: TextStyle(fontSize: 11),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: _kRed,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                ],
              ),
            ),

          const Divider(height: 1),

          // ── Action buttons ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Row(
              children: [
                // Lewati
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: OutlinedButton(
                      onPressed: _connecting
                          ? null
                          : () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF555555),
                        side: const BorderSide(color: Color(0xFFE0E0E0)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        'Lewati',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Hubungkan
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: _connecting || _selectedMac == null
                          ? null
                          : _connectDevice,
                      style: FilledButton.styleFrom(
                        backgroundColor: _kGreen,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: _connecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bluetooth_connected, size: 18),
                      label: Text(
                        _connecting ? 'Menghubungkan...' : 'Hubungkan Printer',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

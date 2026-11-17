import 'package:flutter/material.dart';
import '../widgets/settings_kit.dart';

class PrinterGuidePage extends StatelessWidget {
  const PrinterGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Panduan Printer',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          skSectionLabel('Alur yang disarankan'),
          skCard([
            _step(
              '1',
              'Buat stasiun di Owner Panel',
              'Atur Dapur, Bar, atau stasiun lain dan petakan kategori menu ke stasiun tersebut.',
            ),
            _step(
              '2',
              'Tambahkan printer di perangkat',
              'Buka Pengaturan → Perangkat, lalu tambah printer Bluetooth atau WiFi/LAN.',
            ),
            _step(
              '3',
              'Pilih peran printer',
              'Aktifkan peran Struk atau Dapur. Satu printer boleh memiliki dua peran.',
            ),
            _step(
              '4',
              'Hubungkan printer ke stasiun',
              'Pada konfigurasi printer dapur, pilih stasiun outlet yang sesuai.',
            ),
            _step(
              '5',
              'Tes cetak',
              'Gunakan Tes Cetak sebelum operasional. Untuk LAN, pastikan port 9100 dapat diakses.',
            ),
          ]),
          const SizedBox(height: 20),
          skSectionLabel('Troubleshooting'),
          skCard([
            _hint(
              'Bluetooth',
              'Pastikan printer sudah dipairing di Android, Bluetooth aktif, dan izin perangkat diberikan.',
            ),
            _hint(
              'WiFi/LAN',
              'HP dan printer harus berada di jaringan yang sama. Gunakan IP printer, bukan IP router.',
            ),
            _hint(
              'Tiket tidak keluar',
              'Periksa peran Dapur, autoprint event, kategori, dan stasiun printer.',
            ),
            _hint(
              'Order offline',
              'Printer lokal tetap dapat dipakai. Sinkronisasi transaksi dapat dipantau di Monitoring Perangkat.',
            ),
          ]),
        ],
      ),
    );
  }

  Widget _step(String number, String title, String description) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: SK.ink,
          child: Text(
            number,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: const TextStyle(
                  color: SK.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _hint(String title, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 3),
        Text(
          text,
          style: const TextStyle(color: SK.muted, fontSize: 12, height: 1.45),
        ),
      ],
    ),
  );
}

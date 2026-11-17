import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../pos/presentation/pages/device_settings_page.dart';
import '../../../pos/presentation/pages/kasir_shell.dart';
import '../../../../shared/models/enums.dart';
import '../widgets/settings_kit.dart';
import '../../data/app_settings.dart';
import 'outlet_info_page.dart';
import 'struk_biaya_page.dart';
import 'payment_methods_page.dart';
import 'promo_page.dart';
import 'password_pin_page.dart';
import 'toggle_setting_page.dart';
import 'order_online_setting_page.dart';
import 'device_monitor_page.dart';
import 'printer_guide_page.dart';

/// Hub "Pengaturan" — setting perangkat tersedia untuk staf, sedangkan setting
/// outlet/master data hanya ditampilkan untuk owner/admin.
class SettingsHubPage extends StatelessWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthBloc>().state;
    final outletId = auth is AuthAuthenticated
        ? auth.profile.outletId ?? ''
        : '';
    final selfId = auth is AuthAuthenticated ? auth.profile.id : '';
    final userRole = auth is AuthAuthenticated ? auth.profile.role : null;
    final role = userRole?.value ?? '';
    final canManageOutlet = userRole?.hasAdminAccess ?? false;
    final canViewOrderOnline = canManageOutlet || role == 'manajer';

    final operasional = <Widget>[
      if (canViewOrderOnline)
        SKNavRow(
          icon: Icons.shopping_bag_outlined,
          label: 'Order Online',
          desc: 'Terima pesanan dari QR self-order',
          onTap: () =>
              _push(context, OrderOnlineSettingPage(outletId: outletId)),
        ),
      if (canManageOutlet)
        SKNavRow(
          icon: Icons.receipt_long_outlined,
          label: 'Struk & Biaya',
          desc: 'Tampilan struk, pajak, service charge',
          onTap: () => _push(context, StrukBiayaPage(outletId: outletId)),
        ),
      SKNavRow(
        icon: Icons.print_outlined,
        label: 'Perangkat',
        desc: 'Printer kasir/dapur, koneksi, autoprint',
        onTap: () => _push(context, const DeviceSettingsPage()),
      ),
      SKNavRow(
        icon: Icons.monitor_heart_outlined,
        label: 'Monitoring Perangkat',
        desc: 'Koneksi, sinkronisasi, dan status printer',
        onTap: () => _push(context, DeviceMonitorPage(outletId: outletId)),
      ),
      SKNavRow(
        icon: Icons.menu_book_outlined,
        label: 'Panduan Printer',
        desc: 'Cara mengatur dan mengatasi masalah printer',
        onTap: () => _push(context, const PrinterGuidePage()),
      ),
      SKNavRow(
        icon: Icons.notifications_none,
        label: 'Notifikasi Suara',
        desc: 'Bunyi saat ada pesanan baru',
        onTap: () => _push(
          context,
          ToggleSettingPage(
            title: 'Notifikasi Suara',
            heading: 'Suara notifikasi pesanan',
            description:
                'Bunyikan suara & getar saat ada pesanan baru masuk. '
                'Pengaturan ini berlaku untuk perangkat ini saja.',
            icon: Icons.notifications_none,
            initialValue: AppSettings.soundNotifEnabled,
            onChanged: AppSettings.setSoundNotif,
          ),
        ),
      ),
      if (canManageOutlet)
        SKNavRow(
          icon: Icons.credit_card_outlined,
          label: 'Pembayaran Nontunai',
          desc: 'Metode pembayaran yang aktif',
          onTap: () => _push(context, PaymentMethodsPage(outletId: outletId)),
        ),
      if (canManageOutlet)
        SKNavRow(
          icon: Icons.sell_outlined,
          label: 'Promo',
          desc: 'Kelola promo & voucher',
          onTap: () => _push(context, PromoPage(outletId: outletId)),
        ),
    ];

    final akun = <Widget>[
      if (canManageOutlet)
        SKNavRow(
          icon: Icons.storefront_outlined,
          label: 'Info Outlet',
          desc: 'Nama, alamat, telepon',
          onTap: () => _push(context, OutletInfoPage(outletId: outletId)),
        ),
      SKNavRow(
        icon: Icons.lock_outline,
        label: 'Password & PIN',
        desc: 'Ganti PIN Anda',
        onTap: () => _push(context, PasswordPinPage(selfId: selfId)),
      ),
    ];

    return Scaffold(
      backgroundColor: SK.bg,
      body: Column(
        children: [
          // Header bersih (bukan AppBar Material) — hamburger + judul.
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: SK.border)),
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: KasirShell.openMenu,
                  borderRadius: BorderRadius.circular(6),
                  child: const SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(Icons.menu, size: 20, color: Color(0xFF666666)),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Pengaturan',
                  style: TextStyle(
                    fontSize: 17,
                    color: SK.ink,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                  children: [
                    skSectionLabel('Operasional'),
                    skCard(operasional),
                    const SizedBox(height: 20),
                    skSectionLabel('Akun'),
                    skCard(akun),
                    const SizedBox(height: 24),
                    const Center(child: _VersionLabel()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

/// Label versi app — dibaca otomatis dari build (pubspec version).
class _VersionLabel extends StatefulWidget {
  const _VersionLabel();
  @override
  State<_VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<_VersionLabel> {
  String _v = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _v = info.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _v.isEmpty ? 'Versi' : 'Versi $_v',
      style: const TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
    );
  }
}

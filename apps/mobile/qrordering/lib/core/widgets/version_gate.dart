import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../theme/app_colors.dart';

/// Gerbang versi: bila build aplikasi < `app_config.min_build_android` di server,
/// tampilkan layar blокир "Perlu Update". Fail-open — bila gagal cek / offline,
/// aplikasi tetap jalan normal.
class VersionGate extends StatefulWidget {
  final Widget child;
  const VersionGate({super.key, required this.child});

  @override
  State<VersionGate> createState() => _VersionGateState();
}

class _VersionGateState extends State<VersionGate> {
  bool _outdated = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final r = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('key', 'min_build_android')
          .maybeSingle();
      final min = int.tryParse((r?['value'] as String?) ?? '') ?? 0;
      // appBuild 0 = gagal baca build info → fail-open, jangan salah blokir.
      if (mounted && AppConfig.appBuild > 0 && AppConfig.appBuild < min) {
        setState(() => _outdated = true);
      }
    } catch (_) {
      // Fail-open: jangan blokir bila cek gagal/offline.
    }
  }

  @override
  Widget build(BuildContext context) =>
      _outdated ? const _UpdateRequiredScreen() : widget.child;
}

class _UpdateRequiredScreen extends StatelessWidget {
  const _UpdateRequiredScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.system_update, size: 72, color: AppColors.primary),
              const SizedBox(height: 24),
              const Text(
                'Perlu Update',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Versi aplikasi ini sudah usang. Silakan update ke versi terbaru '
                'untuk melanjutkan (ada perbaikan penting).',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

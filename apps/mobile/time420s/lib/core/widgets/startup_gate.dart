import 'package:flutter/material.dart';

import '../startup/startup_support.dart';

/// Selalu merender UI walaupun bootstrap storage/backend gagal. Sebelumnya
/// seluruh bootstrap terjadi sebelum runApp sehingga satu cache korup membuat
/// aplikasi berhenti selamanya di splash dan tampak hanya bisa pulih lewat
/// reinstall.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.initialize,
    required this.readyBuilder,
    this.deadline = const Duration(seconds: 28),
    this.onFailure,
  });

  final Future<void> Function() initialize;
  final WidgetBuilder readyBuilder;
  final Duration deadline;
  final Future<void> Function(Object error, StackTrace stack)? onFailure;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late Future<void> _startup;

  @override
  void initState() {
    super.initState();
    _startup = _runInitialization();
  }

  void _retry() {
    setState(() {
      _startup = _runInitialization();
    });
  }

  Future<void> _runInitialization() async {
    try {
      await runStartupOperation<void>(
        category: 'STARTUP_DEADLINE_TIMEOUT',
        timeout: widget.deadline,
        operation: widget.initialize,
      );
    } catch (error, stackTrace) {
      debugPrint('StartupGate initialization failed: $error\n$stackTrace');
      await widget.onFailure?.call(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _startup,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError) {
          return widget.readyBuilder(context);
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child:
                        snapshot.connectionState == ConnectionState.done &&
                            snapshot.hasError
                        ? _StartupError(error: snapshot.error!, onRetry: _retry)
                        : const _StartupLoading(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      CircularProgressIndicator(),
      SizedBox(height: 20),
      Text(
        'Menyiapkan aplikasi kasir…',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      SizedBox(height: 6),
      Text(
        'Data lokal sedang diperiksa. Jangan hapus atau instal ulang aplikasi.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFF64748B), height: 1.4),
      ),
    ],
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.storage_rounded, size: 52, color: Color(0xFFDC2626)),
        const SizedBox(height: 16),
        const Text(
          'Tidak dapat membuka aplikasi',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        const Text(
          'Kami mengalami kendala saat menyiapkan aplikasi. Silakan coba '
          'kembali. Data transaksi lokal tidak dihapus.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF475569), height: 1.45),
        ),
        const SizedBox(height: 8),
        const Text(
          'Jika masalah terus terjadi, hubungi administrator.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Coba Lagi'),
          ),
        ),
      ],
    );
  }
}

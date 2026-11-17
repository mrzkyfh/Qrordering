import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Absensi (jam kerja) — clock in/out mandiri, terpisah dari shift kas.
/// Semua role bisa mencatat jam kerja. auth.uid() = staf aktif (pasca PIN).
class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _open; // sesi terbuka (clock_out null)
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final uid = _client.auth.currentUser?.id;
      final rows = await _client
          .from('v_attendance')
          .select()
          .eq('staff_id', uid as Object)
          .order('clock_in', ascending: false)
          .limit(30);
      final list = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _recent = list;
        _open = list
            .where((r) => r['clock_out'] == null)
            .cast<Map<String, dynamic>?>()
            .firstWhere((_) => true, orElse: () => null);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clockIn() async {
    setState(() => _busy = true);
    try {
      await _client.rpc(
        'attendance_clock_in',
        params: {'p_outlet_id': _activeOutletId},
      );
      await _load();
      _snack('Absen masuk tercatat');
    } catch (e) {
      _snack('Gagal absen masuk: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clockOut() async {
    setState(() => _busy = true);
    try {
      await _client.rpc(
        'attendance_clock_out',
        params: {'p_outlet_id': _activeOutletId},
      );
      await _load();
      _snack('Absen pulang tercatat');
    } catch (e) {
      _snack('Gagal absen pulang: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _activeOutletId {
    final auth = context.read<AuthBloc>().state;
    return auth is AuthAuthenticated ? auth.profile.outletId : null;
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? AppColors.primary : AppColors.tealDark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        leading: IconButton(
          key: const Key('attendance-back-button'),
          tooltip: 'Kembali ke Kasir',
          onPressed: () => context.go('/kasir'),
          icon: const Icon(Icons.chevron_left),
        ),
        title: const Text('Absensi'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _statusCard(),
                  const SizedBox(height: 20),
                  const Text(
                    'RIWAYAT',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_recent.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'Belum ada absensi.',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  else
                    ..._recent.map(_historyRow),
                ],
              ),
            ),
    );
  }

  Widget _statusCard() {
    final active = _open != null;
    final df = DateFormat('EEE, d MMM • HH:mm', 'id_ID');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: active ? Colors.green : AppColors.slate400,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                active ? 'Sedang Bekerja' : 'Belum Absen Masuk',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 8),
            Text(
              'Masuk: ${df.format(DateTime.parse(_open!['clock_in']).toLocal())}',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _busy ? null : (active ? _clockOut : _clockIn),
              style: ElevatedButton.styleFrom(
                backgroundColor: active
                    ? AppColors.slate700
                    : AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      active ? 'Absen Pulang' : 'Absen Masuk',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyRow(Map<String, dynamic> r) {
    final df = DateFormat('d MMM', 'id_ID');
    final tf = DateFormat('HH:mm', 'id_ID');
    final inT = DateTime.parse(r['clock_in']).toLocal();
    final outRaw = r['clock_out'];
    final outT = outRaw == null ? null : DateTime.parse(outRaw).toLocal();
    final hours = (r['hours'] as num?)?.toDouble() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  df.format(inT),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${tf.format(inT)} — ${outT == null ? 'aktif' : tf.format(outT)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${hours.toStringAsFixed(1)} jam',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

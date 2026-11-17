import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/offline_queue_service.dart';
import '../../../../shared/services/printer_service.dart';
import '../../../../shared/services/sync_service.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../../../shared/services/transaction_journal_service.dart';
import '../widgets/settings_kit.dart';

/// Ringkasan kesehatan perangkat: koneksi, antrean offline, dan printer lokal.
class DeviceMonitorPage extends StatefulWidget {
  final String outletId;
  const DeviceMonitorPage({super.key, this.outletId = ''});

  @override
  State<DeviceMonitorPage> createState() => _DeviceMonitorPageState();
}

class _DeviceMonitorPageState extends State<DeviceMonitorPage> {
  final _printer = PrinterService();
  List<SavedPrinter> _printers = const [];
  Map<String, PrinterHealth> _healthById = const {};
  List<PrintJob> _jobs = const [];
  PrinterRoutingDiagnostics _routing = const PrinterRoutingDiagnostics();
  bool _loadingPrinters = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    OfflineQueueService.instance.init();
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    await _printer.init();
    final printers = await _printer.listPrinters();
    final healthEntries = await Future.wait(
      printers.map((p) async => MapEntry(p.id, await _printer.checkHealth(p))),
    );
    final jobs = await _printer.pendingPrintJobs();
    final routing = await loadPrinterRoutingDiagnostics(widget.outletId);
    if (!mounted) return;
    setState(() {
      _printers = printers;
      _healthById = Map.fromEntries(healthEntries);
      _jobs = jobs;
      _routing = routing;
      _loadingPrinters = false;
    });
  }

  Future<void> _refresh() async {
    setState(() => _working = true);
    await ConnectivityService.instance.recheck();
    await SyncService.instance.sync();
    await _loadPrinters();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _retryDeadLetters() async {
    setState(() => _working = true);
    await OfflineQueueService.instance.retryAllDeadLetters();
    await SyncService.instance.sync();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _retryDeadLetter(DeadLetterDiagnostic diagnostic) async {
    setState(() => _working = true);
    final restored = await OfflineQueueService.instance.retryDeadLetter(
      diagnostic.key,
    );
    if (restored) await SyncService.instance.sync();
    if (!mounted) return;
    setState(() => _working = false);
    if (!restored) {
      AppToast.error(
        context,
        'Data transaksi tidak dapat dibaca dari perangkat.',
      );
      return;
    }
    final stillRejected = OfflineQueueService.instance.deadLetters().any(
      (entry) => entry.localReference == diagnostic.localReference,
    );
    if (stillRejected) {
      AppToast.error(
        context,
        'Transaksi masih ditolak. Salin detailnya untuk pemeriksaan.',
      );
    } else {
      AppToast.success(context, 'Transaksi diterima untuk sinkronisasi.');
    }
  }

  Future<void> _copyDeadLetter(DeadLetterDiagnostic diagnostic) async {
    await Clipboard.setData(ClipboardData(text: diagnostic.clipboardText));
    if (mounted) {
      AppToast.success(context, 'Detail ${diagnostic.localReference} disalin.');
    }
  }

  Future<void> _retryJournal() async {
    setState(() => _working = true);
    await TransactionJournalService.instance.retryAllAttention();
    await SyncService.instance.sync();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _retryJournalEntry(
    TransactionJournalDiagnostic diagnostic,
  ) async {
    setState(() => _working = true);
    final restored = await TransactionJournalService.instance.retryAttention(
      diagnostic.id,
    );
    if (restored) await SyncService.instance.sync();
    if (!mounted) return;
    setState(() => _working = false);
    if (!restored) {
      AppToast.error(
        context,
        'Operasi ini perlu diperiksa dari layar asal dan tidak diulang otomatis.',
      );
      return;
    }
    final stillRejected = TransactionJournalService.instance
        .diagnostics(attentionOnly: true)
        .any((entry) => entry.id == diagnostic.id);
    if (stillRejected) {
      AppToast.error(
        context,
        'Transaksi masih ditolak. Salin detailnya untuk pemeriksaan.',
      );
    } else {
      AppToast.success(context, 'Transaksi diterima untuk sinkronisasi.');
    }
  }

  Future<void> _copyJournalDiagnostic(
    TransactionJournalDiagnostic diagnostic,
  ) async {
    await Clipboard.setData(ClipboardData(text: diagnostic.clipboardText));
    if (mounted) {
      AppToast.success(context, 'Detail ${diagnostic.reference} disalin.');
    }
  }

  Future<void> _retryPrintJobs() async {
    setState(() => _working = true);
    await _printer.retryAllPrintJobs();
    await _loadPrinters();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _discardPrintJob(PrintJob job) async {
    await _printer.discardPrintJob(job.id);
    await _loadPrinters();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Monitoring Perangkat',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Status terakhir diperbarui saat halaman dibuka atau disegarkan.',
                  style: const TextStyle(fontSize: 12, color: SK.muted),
                ),
              ),
              IconButton(
                tooltip: 'Segarkan dan sinkronkan',
                onPressed: _working ? null : _refresh,
                icon: _working
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          skSectionLabel('Koneksi'),
          ValueListenableBuilder<String>(
            valueListenable: ConnectivityService.instance.detail,
            builder: (_, detail, _) => ValueListenableBuilder<bool>(
              valueListenable: ConnectivityService.instance.online,
              builder: (_, online, _) => skCard([
                _statusRow(
                  Icons.wifi,
                  'Internet & server',
                  online ? 'Terhubung' : 'Offline',
                  online,
                ),
                _statusRow(
                  Icons.alt_route,
                  'Jalur server',
                  AppConfig.usingFallback ? 'Kompatibel Wi-Fi' : 'Langsung',
                  online,
                ),
                _statusRow(
                  Icons.network_check,
                  'Hasil pemeriksaan',
                  detail,
                  online,
                ),
                ValueListenableBuilder<int?>(
                  valueListenable: ConnectivityService.instance.latencyMs,
                  builder: (_, latency, _) => _statusRow(
                    Icons.speed,
                    'Waktu respons',
                    latency == null ? 'Belum tersedia' : '$latency ms',
                    online,
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          skSectionLabel('Antrean Offline'),
          ValueListenableBuilder<int>(
            valueListenable: OfflineQueueService.instance.pendingCount,
            builder: (_, pending, _) => ValueListenableBuilder<int>(
              valueListenable: OfflineQueueService.instance.deadCount,
              builder: (_, dead, _) => skCard([
                _statusRow(
                  Icons.sync,
                  'Menunggu sinkronisasi',
                  '$pending transaksi',
                  pending == 0,
                ),
                _statusRow(
                  Icons.error_outline,
                  'Ditolak server',
                  '$dead transaksi',
                  dead == 0,
                ),
                if (dead > 0) ..._deadLetterRows(),
                if (dead > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : _retryDeadLetters,
                      icon: const Icon(Icons.replay),
                      label: const Text('Coba ulang transaksi ditolak'),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          skSectionLabel('Transaksi Perlu Dipulihkan'),
          ValueListenableBuilder<int>(
            valueListenable: TransactionJournalService.instance.pendingCount,
            builder: (_, pending, _) => ValueListenableBuilder<int>(
              valueListenable:
                  TransactionJournalService.instance.attentionCount,
              builder: (_, attention, _) {
                // Hanya operasi pembayaran yang membawa idempotency key yang
                // aman diulang otomatis. Void/refund/shift/kas masuk-keluar
                // tetap terlihat untuk verifikasi manual agar tidak terjadi
                // mutasi ganda saat respons server hilang.
                final retryableAttention = TransactionJournalService.instance
                    .diagnostics(attentionOnly: true)
                    .where((entry) => entry.retryable)
                    .length;
                return skCard([
                  _statusRow(
                    Icons.sync_problem_outlined,
                    'Menunggu konfirmasi',
                    '$pending transaksi',
                    pending == 0,
                  ),
                  _statusRow(
                    Icons.fact_check_outlined,
                    'Perlu ditinjau',
                    '$attention transaksi',
                    attention == 0,
                  ),
                  if (attention > 0) ..._journalAttentionRows(),
                  if (retryableAttention > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                      child: OutlinedButton.icon(
                        onPressed: _working ? null : _retryJournal,
                        icon: const Icon(Icons.replay),
                        label: const Text('Coba ulang transaksi aman'),
                      ),
                    ),
                  if (attention > retryableAttention)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                      child: Text(
                        'Sebagian operasi memerlukan pemeriksaan manual agar tidak tercatat dua kali.',
                        style: TextStyle(fontSize: 12, color: SK.muted),
                      ),
                    ),
                ]);
              },
            ),
          ),
          const SizedBox(height: 20),
          skSectionLabel('Antrean Cetak'),
          skCard([
            if (_jobs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Tidak ada pekerjaan cetak yang tertunda.',
                  style: TextStyle(fontSize: 13, color: SK.muted),
                ),
              )
            else ...[
              for (final job in _jobs) _printJobRow(job),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                child: OutlinedButton.icon(
                  onPressed: _working ? null : _retryPrintJobs,
                  icon: const Icon(Icons.replay),
                  label: const Text('Coba ulang semua cetak'),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 20),
          skSectionLabel('Diagnostik Routing'),
          skCard([
            if (_routing.errors.isEmpty && _routing.warnings.isEmpty)
              _statusRow(
                Icons.check_circle_outline,
                'Routing station',
                'Siap',
                true,
              ),
            for (final error in _routing.errors)
              _statusRow(Icons.error_outline, 'Perlu diperbaiki', error, false),
            for (final warning in _routing.warnings)
              _statusRow(Icons.info_outline, 'Informasi', warning, true),
          ]),
          const SizedBox(height: 20),
          skSectionLabel('Printer Perangkat Ini'),
          skCard([
            if (_loadingPrinters)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_printers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Belum ada printer. Tambahkan dari menu Perangkat.',
                  style: TextStyle(fontSize: 13, color: SK.muted),
                ),
              )
            else
              for (final printer in _printers) _printerRow(printer),
          ]),
        ],
      ),
    );
  }

  List<Widget> _journalAttentionRows() {
    final entries = TransactionJournalService.instance.diagnostics(
      attentionOnly: true,
    )..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries
        .map(
          (diagnostic) => JournalDiagnosticTile(
            diagnostic: diagnostic,
            busy: _working,
            onCopy: () => _copyJournalDiagnostic(diagnostic),
            onRetry: diagnostic.retryable
                ? () => _retryJournalEntry(diagnostic)
                : null,
          ),
        )
        .toList();
  }

  List<Widget> _deadLetterRows() {
    final entries = OfflineQueueService.instance.deadLetters()
      ..sort((a, b) => b.failedAt.compareTo(a.failedAt));
    return entries
        .map(
          (diagnostic) => DeadLetterDiagnosticTile(
            diagnostic: diagnostic,
            busy: _working,
            onCopy: () => _copyDeadLetter(diagnostic),
            onRetry: () => _retryDeadLetter(diagnostic),
          ),
        )
        .toList();
  }

  Widget _statusRow(IconData icon, String label, String value, bool ok) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 20, color: ok ? SK.ink : Colors.redAccent),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  color: ok ? SK.muted : Colors.redAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _printerRow(SavedPrinter printer) {
    final health = _healthById[printer.id];
    final value = health == null
        ? 'Memeriksa...'
        : '${health.message}${health.latencyMs == null ? '' : ' · ${health.latencyMs} ms'}';
    return _statusRow(
      printer.isLan ? Icons.lan : Icons.print,
      printer.name,
      value,
      health?.ok ?? printer.enabled,
    );
  }

  Widget _printJobRow(PrintJob job) {
    final printer = _printers.where((p) => p.id == job.printerId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          const Icon(
            Icons.print_disabled_outlined,
            size: 20,
            color: Colors.redAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.label, style: const TextStyle(fontSize: 14)),
                Text(
                  '${printer?.name ?? 'Printer dihapus'} · Percobaan ${job.attempts + 1}',
                  style: const TextStyle(fontSize: 11, color: SK.muted),
                ),
                if (job.lastError.isNotEmpty)
                  Text(
                    job.lastError,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Hapus pekerjaan',
            onPressed: () => _discardPrintJob(job),
            icon: const Icon(Icons.delete_outline, size: 19),
          ),
          IconButton(
            tooltip: 'Coba ulang',
            onPressed: _working
                ? null
                : () async {
                    setState(() => _working = true);
                    await _printer.retryPrintJob(job.id);
                    await _loadPrinters();
                    if (mounted) setState(() => _working = false);
                  },
            icon: const Icon(Icons.replay, size: 19),
          ),
        ],
      ),
    );
  }
}

/// Kartu diagnostik dipisah dari halaman agar layout sempit dapat diuji tanpa
/// menginisialisasi koneksi, printer, dan Supabase.
class DeadLetterDiagnosticTile extends StatelessWidget {
  final DeadLetterDiagnostic diagnostic;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRetry;

  const DeadLetterDiagnosticTile({
    super.key,
    required this.diagnostic,
    required this.busy,
    required this.onCopy,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      leading: const Icon(
        Icons.receipt_long_outlined,
        size: 20,
        color: Colors.redAccent,
      ),
      title: Text(
        diagnostic.localReference,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        diagnostic.readableReason,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: SK.muted),
      ),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: SK.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _diagnosticValue('ID till transaksi', diagnostic.shiftId),
              if (diagnostic.originalShiftId != null)
                _diagnosticValue('ID till asal', diagnostic.originalShiftId),
              _diagnosticValue(
                'Waktu transaksi',
                _displayTimestamp(diagnostic.createdAt),
              ),
              _diagnosticValue(
                'Waktu ditolak',
                _displayTimestamp(diagnostic.failedAt),
              ),
              _diagnosticValue('ID kasir', diagnostic.createdBy),
              _diagnosticValue('Metode pembayaran', diagnostic.paymentSummary),
              if (diagnostic.shiftStartedAt != null)
                _diagnosticValue(
                  'Till mulai',
                  _displayTimestamp(diagnostic.shiftStartedAt),
                ),
              if (diagnostic.shiftVerifiedAt != null)
                _diagnosticValue(
                  'Till terakhir diverifikasi',
                  _displayTimestamp(diagnostic.shiftVerifiedAt),
                ),
              if (diagnostic.shiftSource != null)
                _diagnosticValue('Sumber till', diagnostic.shiftSource),
              _diagnosticValue('Pesan server', diagnostic.error),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : onCopy,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('Salin detail'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : onRetry,
                    icon: const Icon(Icons.replay, size: 17),
                    label: const Text('Coba transaksi ini'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _diagnosticValue(String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            color: SK.muted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value?.trim().isNotEmpty == true ? value! : '-',
          style: const TextStyle(fontSize: 12.5, color: SK.ink, height: 1.35),
        ),
      ],
    ),
  );

  String _displayTimestamp(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(parsed.day)}/${two(parsed.month)}/${parsed.year} '
        '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }
}

/// Detail untuk pembayaran/operasi yang respons akhirnya belum pasti. Aksi
/// sensitif tidak diberi tombol retry agar void, refund, atau kas tidak ganda.
class JournalDiagnosticTile extends StatelessWidget {
  final TransactionJournalDiagnostic diagnostic;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback? onRetry;

  const JournalDiagnosticTile({
    super.key,
    required this.diagnostic,
    required this.busy,
    required this.onCopy,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      leading: Icon(
        diagnostic.isCorrupt
            ? Icons.data_object_outlined
            : Icons.fact_check_outlined,
        size: 20,
        color: Colors.orange.shade800,
      ),
      title: Text(
        diagnostic.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '${diagnostic.reference} · ${diagnostic.readableReason}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: SK.muted),
      ),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBF5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFF0D7B2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _journalValue('ID jurnal', diagnostic.id),
              if (diagnostic.orderId != null)
                _journalValue('ID order', diagnostic.orderId),
              if (diagnostic.outletId != null)
                _journalValue('ID outlet', diagnostic.outletId),
              if (diagnostic.shiftId != null)
                _journalValue('ID till', diagnostic.shiftId),
              if (diagnostic.expectedUserId != null)
                _journalValue('ID pengguna', diagnostic.expectedUserId),
              if (diagnostic.operation != null)
                _journalValue('Operasi', diagnostic.operation),
              _journalValue('Pembayaran / nominal', diagnostic.amountSummary),
              _journalValue('Percobaan', diagnostic.attempts.toString()),
              _journalValue(
                'Terakhir diperbarui',
                _journalDisplayTimestamp(diagnostic.updatedAt),
              ),
              _journalValue('Pesan terakhir', diagnostic.lastError),
              _journalValue('Tindakan aman', diagnostic.guidance),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : onCopy,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('Salin detail'),
                  ),
                  if (onRetry != null)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : onRetry,
                      icon: const Icon(Icons.replay, size: 17),
                      label: const Text('Coba pembayaran ini'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _journalValue(String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            color: SK.muted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value?.trim().isNotEmpty == true ? value! : '-',
          style: const TextStyle(fontSize: 12.5, color: SK.ink, height: 1.35),
        ),
      ],
    ),
  );

  String _journalDisplayTimestamp(String raw) {
    if (raw.trim().isEmpty) return '-';
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(parsed.day)}/${two(parsed.month)}/${parsed.year} '
        '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

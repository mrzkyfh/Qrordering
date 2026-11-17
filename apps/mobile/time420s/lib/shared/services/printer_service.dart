import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Socket;
import 'package:bluetooth_print_plus/bluetooth_print_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Hasil percobaan cetak struk.
///
/// `skipped` sengaja dipisah dari `printed`: struk yang DILEWATI (autoprint
/// dimatikan, atau tak ada printer ber-peran Struk) tidak boleh ditandai
/// sudah-dicetak, karena batas cetak akan memblokir cetak ulangnya selamanya.
/// Dan tidak boleh memunculkan toast "gagal" — melewati adalah pilihan user.
enum PrintOutcome {
  printed,
  skipped,
  failed;

  bool get isPrinted => this == PrintOutcome.printed;
  bool get isFailed => this == PrintOutcome.failed;
}

enum PrinterHealthStatus { ready, disconnected, failed, unsupported }

class PrinterHealth {
  final PrinterHealthStatus status;
  final int? latencyMs;
  final String message;

  const PrinterHealth({
    required this.status,
    this.latencyMs,
    required this.message,
  });

  bool get ok => status == PrinterHealthStatus.ready;
}

/// Pekerjaan cetak lokal yang gagal. Disimpan di perangkat yang menjalankan
/// POS, karena koneksi Bluetooth/LAN memang bersifat device-local.
class PrintJob {
  final String id;
  final String requestId;
  final String intent;
  final String printerId;
  final String label;
  final List<int> bytes;
  final DateTime createdAt;
  final int attempts;
  final String lastError;
  final int copies;
  final String? kitchenOrderId;
  final String? kitchenDeviceId;
  final bool awaitingServerAck;

  const PrintJob({
    required this.id,
    this.requestId = '',
    this.intent = 'unknown',
    required this.printerId,
    required this.label,
    required this.bytes,
    required this.createdAt,
    this.attempts = 0,
    this.lastError = '',
    this.copies = 1,
    this.kitchenOrderId,
    this.kitchenDeviceId,
    this.awaitingServerAck = false,
  });

  bool get isKitchenJob =>
      kitchenOrderId?.isNotEmpty == true && kitchenDeviceId?.isNotEmpty == true;

  PrintJob copyWith({
    int? attempts,
    String? lastError,
    int? copies,
    bool? awaitingServerAck,
  }) => PrintJob(
    id: id,
    requestId: requestId,
    intent: intent,
    printerId: printerId,
    label: label,
    bytes: bytes,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    lastError: lastError ?? this.lastError,
    copies: copies ?? this.copies,
    kitchenOrderId: kitchenOrderId,
    kitchenDeviceId: kitchenDeviceId,
    awaitingServerAck: awaitingServerAck ?? this.awaitingServerAck,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'requestId': requestId,
    'intent': intent,
    'printerId': printerId,
    'label': label,
    'bytes': base64Encode(bytes),
    'createdAt': createdAt.toIso8601String(),
    'attempts': attempts,
    'lastError': lastError,
    'copies': copies,
    'kitchenOrderId': kitchenOrderId,
    'kitchenDeviceId': kitchenDeviceId,
    'awaitingServerAck': awaitingServerAck,
  };

  factory PrintJob.fromMap(Map<String, dynamic> m) => PrintJob(
    id: m['id'] as String? ?? '',
    requestId: m['requestId'] as String? ?? m['id'] as String? ?? '',
    intent: m['intent'] as String? ?? 'legacy_retry',
    printerId: m['printerId'] as String? ?? '',
    label: m['label'] as String? ?? 'Cetak',
    bytes: base64Decode(m['bytes'] as String? ?? ''),
    createdAt:
        DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
    attempts: (m['attempts'] as num?)?.toInt() ?? 0,
    lastError: m['lastError'] as String? ?? '',
    copies: ((m['copies'] as num?)?.toInt() ?? 1).clamp(1, 5),
    kitchenOrderId: m['kitchenOrderId'] as String?,
    kitchenDeviceId: m['kitchenDeviceId'] as String?,
    awaitingServerAck: m['awaitingServerAck'] as bool? ?? false,
  );
}

/// Service untuk pair + cetak ke Bluetooth thermal printer (ESC/POS).
///
/// **Platform support:**
/// - Android: full support via `bluetooth_print_plus`
/// - iOS / web / desktop: no-op (returns sensible defaults). Plugin
///   `bluetooth_print_plus` di-exclude dari iOS Pod install karena GSDK
///   precompiled framework tidak punya simulator arm64 slice.
///
/// Singleton.
class PrinterService {
  PrinterService._();
  static final PrinterService _instance = PrinterService._();
  factory PrinterService() => _instance;

  static const _prefsKeyLastMac = 'printer_last_mac';
  static const _prefsKeyLastName = 'printer_last_name';
  // Registry multi-printer (Fase 3): daftar printer tersimpan, printer kasir
  // (default untuk struk pelanggan), dan peta stasiun → printer.
  static const _prefsKeyPrinters = 'printers_json';
  static const _prefsKeyDefaultPrinter = 'printer_default_id';
  // 'station_printer_json' tidak lagi ditulis/dibaca — subsistem peta stasiun
  // dihapus (yatim). Data lama di HP dibiarkan menganggur & tak berbahaya.
  // Batasan cetak struk (receipt_limit_print): id order yang struk-nya sudah
  // dicetak, agar tidak tercetak ganda saat toggle aktif.
  static const _prefsKeyPrintedReceipts = 'printed_receipt_ids';
  static const _prefsKeyPrintJobs = 'print_jobs_json';
  Timer? _pendingRetryTimer;
  Duration _pendingRetryDelay = const Duration(seconds: 30);
  bool _pendingRetriesPaused = false;
  Future<void>? _pendingRetryRun;
  Future<bool> Function(SavedPrinter, List<int>)? _physicalSenderForTest;

  static String newPrintRequestId(String intent, String reference) =>
      '$intent-$reference-${DateTime.now().microsecondsSinceEpoch}';

  @visibleForTesting
  void setPhysicalSenderForTest(
    Future<bool> Function(SavedPrinter, List<int>)? sender,
  ) {
    _physicalSenderForTest = sender;
  }

  void _schedulePendingPrintRetry() {
    // Produksi kasir saat ini Android. Hindari timer native pada test/desktop
    // yang tidak memiliki stack Bluetooth aplikasi.
    if (_pendingRetriesPaused ||
        !isSupported ||
        _pendingRetryTimer?.isActive == true) {
      return;
    }
    _pendingRetryTimer = Timer(_pendingRetryDelay, () async {
      _pendingRetryTimer = null;
      await retryPendingPrintJobs(increaseDelay: true);
    });
  }

  /// True bila struk order ini pernah dicetak (untuk enforce batas cetak).
  Future<bool> receiptAlreadyPrinted(String orderId) async {
    if (orderId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefsKeyPrintedReceipts)?.contains(orderId) ??
        false;
  }

  /// Tandai struk order ini sudah dicetak (simpan maks 500 id terakhir).
  Future<void> markReceiptPrinted(String orderId) async {
    if (orderId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_prefsKeyPrintedReceipts) ?? <String>[];
    if (list.contains(orderId)) return;
    list.add(orderId);
    if (list.length > 500) list.removeRange(0, list.length - 500);
    await prefs.setStringList(_prefsKeyPrintedReceipts, list);
  }

  Future<List<PrintJob>> pendingPrintJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyPrintJobs);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      final parsed = list
          .whereType<Map<String, dynamic>>()
          .map(PrintJob.fromMap)
          .where(
            (job) =>
                job.id.isNotEmpty &&
                (job.bytes.isNotEmpty ||
                    (job.isKitchenJob && job.awaitingServerAck)),
          )
          .toList();
      // Job biasa versi lama tidak mempunyai identity/intent, sehingga aman
      // tidaknya replay setelah restart tidak bisa dibuktikan. Buang job itu
      // sekali saat migrasi; acknowledgement/tiket dapur ber-lease tetap aman.
      final safe = parsed
          .where((job) => job.isKitchenJob || job.intent != 'legacy_retry')
          .toList();
      if (safe.length != parsed.length) await _savePrintJobs(safe);
      return safe;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _savePrintJobs(List<PrintJob> jobs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKeyPrintJobs,
      jsonEncode(jobs.map((job) => job.toMap()).toList()),
    );
  }

  Future<void> _enqueuePrintJob(
    SavedPrinter printer,
    List<int> bytes,
    String label,
    String error, {
    int copies = 1,
    String? kitchenOrderId,
    String? kitchenDeviceId,
    bool awaitingServerAck = false,
    String requestId = '',
    String intent = 'unknown',
  }) async {
    final jobs = List<PrintJob>.from(await pendingPrintJobs());
    if (requestId.isNotEmpty &&
        jobs.any(
          (job) =>
              job.requestId == requestId &&
              job.printerId == printer.id &&
              listEquals(job.bytes, bytes),
        )) {
      debugPrint(
        'PRINT_QUEUE_SKIP_DUPLICATE request=$requestId intent=$intent '
        'target=${printer.id}',
      );
      return;
    }
    jobs.add(
      PrintJob(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        requestId: requestId,
        intent: intent,
        printerId: printer.id,
        label: label,
        bytes: bytes,
        createdAt: DateTime.now(),
        lastError: error,
        copies: copies.clamp(1, 5),
        kitchenOrderId: kitchenOrderId,
        kitchenDeviceId: kitchenDeviceId,
        awaitingServerAck: awaitingServerAck,
      ),
    );
    // Batasi job biasa, tetapi jangan pernah membuang tiket dapur yang masih
    // memegang lease server. Menghapus job dapur di sini dapat membuat makanan
    // tidak tercetak sementara server masih mencegah perangkat lain mengambil.
    final kitchenJobs = jobs.where((job) => job.isKitchenJob).toList();
    final regularJobs = jobs.where((job) => !job.isKitchenJob).toList();
    final keptRegular = regularJobs.length > 100
        ? regularJobs.sublist(regularJobs.length - 100)
        : regularJobs;
    final kept = [...kitchenJobs, ...keptRegular];
    await _savePrintJobs(kept);
    _schedulePendingPrintRetry();
  }

  Future<bool> retryPrintJob(String jobId) async {
    final jobs = List<PrintJob>.from(await pendingPrintJobs());
    final index = jobs.indexWhere((job) => job.id == jobId);
    if (index < 0) return false;
    final job = jobs[index];
    debugPrint(
      'PRINT_RETRY job=${job.id} request=${job.requestId} '
      'intent=${job.intent} target=${job.printerId} '
      'attempt=${job.attempts + 1}',
    );
    if (job.isKitchenJob) {
      final orderId = job.kitchenOrderId!;
      final deviceId = job.kitchenDeviceId!;
      if (job.awaitingServerAck) {
        return _finishKitchenJobsIfReady(jobs, orderId, deviceId);
      }
      final ownsLease = await _renewKitchenLease(orderId, deviceId);
      if (!ownsLease) {
        jobs[index] = job.copyWith(
          attempts: job.attempts + 1,
          lastError: 'Klaim tiket dapur dimiliki perangkat lain',
        );
        await _savePrintJobs(jobs);
        return false;
      }
    }
    final printer = await _printerById(job.printerId);
    if (printer == null) {
      jobs[index] = job.copyWith(
        attempts: job.attempts + 1,
        lastError: 'Printer sudah tidak terdaftar',
      );
      await _savePrintJobs(jobs);
      return false;
    }
    var sent = 0;
    for (var i = 0; i < job.copies; i++) {
      debugPrint(
        'PRINT_SEND request=${job.requestId} intent=${job.intent} '
        'target=${printer.id} retry=${job.attempts + 1} '
        'copy=${i + 1}/${job.copies} '
        'timestamp=${DateTime.now().toIso8601String()}',
      );
      if (!await _synchronized(() => _sendOnce(printer, job.bytes))) break;
      sent++;
    }
    if (sent == job.copies) {
      if (job.isKitchenJob) {
        jobs[index] = job.copyWith(
          attempts: job.attempts + 1,
          lastError: '',
          copies: 1,
          awaitingServerAck: true,
        );
        await _savePrintJobs(jobs);
        return _finishKitchenJobsIfReady(
          jobs,
          job.kitchenOrderId!,
          job.kitchenDeviceId!,
        );
      }
      jobs.removeAt(index);
    } else {
      jobs[index] = job.copyWith(
        attempts: job.attempts + 1,
        lastError: 'Koneksi printer gagal',
        copies: job.copies - sent,
      );
    }
    await _savePrintJobs(jobs);
    return sent == job.copies;
  }

  Future<bool> _renewKitchenLease(String orderId, String deviceId) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'renew_kitchen_print_claim',
        params: {'p_order_id': orderId, 'p_device_id': deviceId},
      );
      return result == true;
    } catch (error) {
      debugPrint('PrinterService renew kitchen lease error: $error');
      return false;
    }
  }

  Future<bool> _finishKitchenJobsIfReady(
    List<PrintJob> jobs,
    String orderId,
    String deviceId,
  ) async {
    final sameOrder = jobs.where(
      (job) => job.kitchenOrderId == orderId && job.kitchenDeviceId == deviceId,
    );
    if (sameOrder.any((job) => !job.awaitingServerAck)) return false;
    try {
      final result = await Supabase.instance.client.rpc(
        'complete_kitchen_print',
        params: {'p_order_id': orderId, 'p_device_id': deviceId},
      );
      if (result != true) return false;
      jobs.removeWhere(
        (job) =>
            job.kitchenOrderId == orderId && job.kitchenDeviceId == deviceId,
      );
      await _savePrintJobs(jobs);
      return true;
    } catch (error) {
      debugPrint('PrinterService complete kitchen print error: $error');
      return false;
    }
  }

  /// Simpan acknowledgement terpisah ketika kertas sudah keluar tetapi RPC
  /// penyelesaian belum dapat mencapai server. Retry berikutnya hanya mengirim
  /// metadata—byte tiket tidak pernah dicetak ulang.
  Future<void> enqueueKitchenAcknowledgement({
    required String orderId,
    required String deviceId,
  }) async {
    final jobs = await pendingPrintJobs();
    if (jobs.any(
      (job) =>
          job.kitchenOrderId == orderId &&
          job.kitchenDeviceId == deviceId &&
          job.awaitingServerAck,
    )) {
      return;
    }
    await _enqueuePrintJob(
      const SavedPrinter(id: '', name: ''),
      const [],
      'Konfirmasi tiket dapur',
      'Menunggu sinkronisasi server',
      kitchenOrderId: orderId,
      kitchenDeviceId: deviceId,
      awaitingServerAck: true,
    );
  }

  Future<int> retryAllPrintJobs() async {
    final jobs = List<PrintJob>.from(await pendingPrintJobs());
    var success = 0;
    for (final job in jobs) {
      if (await retryPrintJob(job.id)) success++;
    }
    return success;
  }

  /// Coba ulang antrean secara best-effort ketika aplikasi/perangkat kembali
  /// aktif. Sinkronisasi global mencegah tabrakan dengan pekerjaan cetak baru.
  Future<void> retryPendingPrintJobs({bool increaseDelay = false}) async {
    if (_pendingRetriesPaused || !isSupported) return;
    final active = _pendingRetryRun;
    if (active != null) return active;
    final run = _retryPendingPrintJobs(increaseDelay: increaseDelay);
    _pendingRetryRun = run;
    try {
      await run;
    } finally {
      if (identical(_pendingRetryRun, run)) _pendingRetryRun = null;
    }
  }

  Future<void> _retryPendingPrintJobs({required bool increaseDelay}) async {
    if ((await pendingPrintJobs()).isEmpty || _pendingRetriesPaused) return;
    await retryAllPrintJobs();
    if (_pendingRetriesPaused) return;
    if ((await pendingPrintJobs()).isNotEmpty) {
      if (increaseDelay) {
        final seconds = (_pendingRetryDelay.inSeconds * 2).clamp(30, 120);
        _pendingRetryDelay = Duration(seconds: seconds);
      }
      _schedulePendingPrintRetry();
    } else {
      _pendingRetryDelay = const Duration(seconds: 30);
    }
  }

  /// Batalkan timer dan tunggu retry aktif sebelum sesi staf ditutup.
  Future<void> pausePendingPrintRetries() async {
    _pendingRetriesPaused = true;
    _pendingRetryTimer?.cancel();
    _pendingRetryTimer = null;
    await _pendingRetryRun;
  }

  /// Lanjutkan acknowledgement/tiket tertunda setelah staf kembali login.
  void resumePendingPrintRetries() {
    _pendingRetriesPaused = false;
    unawaited(retryPendingPrintJobs());
  }

  Future<String> devicePrintId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'printer_device_id_v1';
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final created =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    await prefs.setString(key, created);
    return created;
  }

  Future<void> discardPrintJob(String jobId) async {
    final jobs = List<PrintJob>.from(await pendingPrintJobs());
    jobs.removeWhere((job) => job.id == jobId);
    await _savePrintJobs(jobs);
  }

  /// True hanya di Android — di luar platform itu service jadi no-op.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  bool _initialized = false;
  bool _listenersAttached = false;
  BluetoothDevice? _connectedDevice;

  bool get isConnected => _connectedDevice != null;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  // ── Antrean cetak global ────────────────────────────────────────────────────
  // Radio Bluetooth hanya bisa memegang SATU koneksi printer. Cetak dapat dipicu
  // dari banyak sumber sekaligus: autoprint bayar, order web masuk (realtime
  // listener → unawaited), dan cetak manual. Bila dua job berjalan berbarengan,
  // masing-masing memanggil _ensureConnectedToMac ke MAC berbeda dan saling
  // MEMUTUS koneksi di tengah proses tulis → struk kasir & tiket dapur "error".
  //
  // Semua jalur cetak melewati _synchronized: job dijalankan satu per satu,
  // berurutan (connect → tulis → reconnect printer berikutnya → tulis), sehingga
  // satu radio BT bisa melayani banyak printer/departemen tanpa tabrakan.
  Future<void> _printGate = Future<void>.value();

  // Jeda antar-cetak (ms) yang bisa diatur user. Di setup 1 printer dua peran
  // (struk + dapur), struk kasir dan tiket dapur keluar dari kertas yang sama
  // beruntun; jeda ini memberi kasir/dapur waktu menyobek struk pertama sebelum
  // yang kedua tercetak. Di-cache agar tak baca prefs tiap job. -1 = belum load.
  static const _prefsKeyPrintGapMs = 'print_gap_ms';
  int _printGapMs = -1;

  /// Jeda antar-cetak dalam milidetik (default 0 = tanpa jeda).
  Future<int> printGapMs() async {
    if (_printGapMs >= 0) return _printGapMs;
    final prefs = await SharedPreferences.getInstance();
    _printGapMs = prefs.getInt(_prefsKeyPrintGapMs) ?? 0;
    return _printGapMs;
  }

  /// Atur jeda antar-cetak (milidetik, di-clamp 0..10000).
  Future<void> setPrintGapMs(int ms) async {
    _printGapMs = ms.clamp(0, 10000);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKeyPrintGapMs, _printGapMs);
  }

  /// Jalankan [action] lewat antrean cetak (serial). Hanya untuk test —
  /// mutex-nya private, tetapi properti "berurutan, tak interleave" perlu dijaga.
  @visibleForTesting
  Future<T> runSerializedForTest<T>(Future<T> Function() action) =>
      _synchronized(action);

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _printGate = _printGate.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        // Jeda DITEMPEL setelah job selesai, di dalam rantai gate: pemanggil
        // job ini sudah lanjut (completer complete di atas), tapi job BERIKUTNYA
        // di antrean baru mulai setelah jeda → struk & tiket dapur berspasi.
        try {
          final gap = await printGapMs();
          if (gap > 0) await Future.delayed(Duration(milliseconds: gap));
        } catch (e) {
          // Kegagalan membaca preferensi jeda tidak boleh merusak rantai mutex
          // dan membuat seluruh job cetak berikutnya menggantung.
          debugPrint('PrinterService print gap error: $e');
        }
      }
    });
    return completer.future;
  }

  // ── Stream reaktif untuk UI ────────────────────────────────────────────────
  /// True bila Bluetooth perangkat menyala.
  Stream<bool> get blueOnStream => isSupported
      ? BluetoothPrintPlus.blueState.map((s) => s == BlueState.blueOn)
      : Stream<bool>.value(false);

  /// True bila printer terhubung.
  Stream<bool> get connectedStream => isSupported
      ? BluetoothPrintPlus.connectState.map((s) => s == ConnectState.connected)
      : Stream<bool>.value(false);

  /// Daftar device hasil scan (realtime).
  Stream<List<BluetoothDevice>> get scanResultsStream => isSupported
      ? BluetoothPrintPlus.scanResults
      : const Stream<List<BluetoothDevice>>.empty();

  /// True selama scan berlangsung.
  Stream<bool> get scanningStream =>
      isSupported ? BluetoothPrintPlus.isScanning : Stream<bool>.value(false);

  Future<void> init() async {
    if (!isSupported) return;
    if (_initialized) return;
    _initialized = true;
    _attachListeners();
  }

  /// Jaga `_connectedDevice` tetap sinkron: plugin melaporkan putus koneksi
  /// lewat `connectState`, bukan via panggilan kita.
  void _attachListeners() {
    if (_listenersAttached || !isSupported) return;
    _listenersAttached = true;
    BluetoothPrintPlus.connectState.listen((s) {
      if (s == ConnectState.disconnected) _connectedDevice = null;
    });
  }

  static const _btChannel = MethodChannel('time420s/bluetooth');

  /// Minta sistem menyalakan Bluetooth (prompt "Izinkan app menyalakan
  /// Bluetooth?"). Butuh izin BLUETOOTH_CONNECT (di-request dulu). Hanya
  /// Android. Mengembalikan true bila prompt berhasil ditampilkan.
  Future<bool> requestEnableBluetooth() async {
    if (!isSupported) return false;
    // BLUETOOTH_CONNECT wajib untuk ACTION_REQUEST_ENABLE di Android 12+.
    if (!await ensurePermissions()) return false;
    try {
      final ok = await _btChannel.invokeMethod<bool>('requestEnable');
      return ok ?? false;
    } catch (e) {
      debugPrint('PrinterService.requestEnableBluetooth error: $e');
      return false;
    }
  }

  Future<bool> isBluetoothOn() async {
    if (!isSupported) return false;
    try {
      return BluetoothPrintPlus.isBlueOn;
    } catch (e) {
      debugPrint('PrinterService.isBluetoothOn error: $e');
      return false;
    }
  }

  /// Pastikan Bluetooth menyala sebelum scan/cetak. Bila mati: tampilkan prompt
  /// sistem "Izinkan app menyalakan Bluetooth?" lalu TUNGGU sampai user benar-
  /// benar mengaktifkannya (polling ringan hingga [timeout]) — bukan menyerah
  /// setelah jeda tetap yang terlalu singkat. Kembalikan status akhir Bluetooth.
  Future<bool> ensureBluetoothOn({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!isSupported) return false;
    if (await isBluetoothOn()) return true;

    // requestEnableBluetooth() sudah meminta izin BLUETOOTH_CONNECT + memicu
    // prompt sistem ACTION_REQUEST_ENABLE.
    await requestEnableBluetooth();

    // Tunggu perubahan status ke ON. Polling 400ms: begitu user menekan
    // "Izinkan", app langsung lanjut tanpa harus buka-tutup dialog.
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (await isBluetoothOn()) return true;
    }
    return await isBluetoothOn();
  }

  /// Minta izin runtime Bluetooth — scan & connect. Location TIDAK diminta
  /// karena BLUETOOTH_SCAN di manifest pakai `neverForLocation`; tanpa flag
  /// itu, classic BT scan di Android 12+ butuh lokasi dan jika ditolak
  /// hasilnya 0 device tanpa error (bisu).
  Future<bool> ensurePermissions() async {
    if (!isSupported) return true;
    Future<bool> req(Permission p) async {
      try {
        final s = await p.request();
        return s.isGranted || s.isLimited;
      } catch (e) {
        debugPrint('PrinterService.ensurePermissions ${p.toString()}: $e');
        return false;
      }
    }

    final scan = await req(Permission.bluetoothScan);
    final connect = await req(Permission.bluetoothConnect);
    return scan && connect;
  }

  /// Mulai scan. `BluetoothPrintPlus.startScan` sudah blocking sampai timeout
  /// (atau `stopScan`) dan mengelola stream `scanResults`/`isScanning` sendiri,
  /// jadi JANGAN tambah timeout/stop manual (dulu bikin scan dobel-kontrol &
  /// indikator berhenti seketika). Lempar bila izin ditolak agar UI jelas.
  Future<List<BluetoothDevice>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isSupported) return const [];
    _attachListeners();
    final granted = await ensurePermissions();
    if (!granted) {
      throw const PrinterPermissionException();
    }
    try {
      final r = await BluetoothPrintPlus.startScan(timeout: timeout);
      return r is List ? List<BluetoothDevice>.from(r) : const [];
    } catch (e) {
      if (e is PrinterPermissionException) rethrow;
      debugPrint('PrinterService.scan error: $e');
      return const [];
    }
  }

  /// Hentikan scan yang sedang berjalan (mis. saat user keluar halaman).
  Future<void> stopScan() async {
    if (!isSupported) return;
    try {
      await BluetoothPrintPlus.stopScan();
    } catch (_) {}
  }

  Future<bool> connect(
    BluetoothDevice device, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!isSupported) return false;
    if (!await ensurePermissions()) return false;
    _attachListeners();
    StreamSubscription<ConnectState>? sub;
    try {
      // Putus koneksi lama dulu agar state mulai bersih dari 'disconnected'
      // → event 'connected' berikutnya dijamin fresh.
      try {
        if (BluetoothPrintPlus.isConnected) {
          await BluetoothPrintPlus.disconnect();
          await Future.delayed(const Duration(milliseconds: 300));
        }
      } catch (_) {}

      // `BluetoothPrintPlus.connect` fire-and-forget — hasil koneksi datang
      // lewat stream `connectState`. Tunggu HANYA 'connected'; kegagalan
      // ditentukan oleh timeout. JANGAN complete(false) pada 'disconnected' —
      // saat proses connect sering ada emit 'disconnected' transient yang
      // dulu menutup completer terlalu dini → "sering gagal terhubung".
      final completer = Completer<bool>();
      var waitingForConnect = false;
      sub = BluetoothPrintPlus.connectState.listen((s) {
        if (!waitingForConnect) return;
        if (s == ConnectState.connected && !completer.isCompleted) {
          completer.complete(true);
        }
      });
      waitingForConnect = true;
      await BluetoothPrintPlus.connect(device);
      final ok = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );

      if (!ok) {
        debugPrint('PrinterService.connect: gagal/timeout ${device.address}');
        return false;
      }

      _connectedDevice = device;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyLastMac, device.address);
      await prefs.setString(_prefsKeyLastName, device.name);
      return true;
    } catch (e) {
      debugPrint('PrinterService.connect error: $e');
      return false;
    } finally {
      await sub?.cancel();
    }
  }

  Future<bool> tryAutoReconnect() async {
    if (!isSupported) return false;
    if (isConnected) return true;
    final prefs = await SharedPreferences.getInstance();
    final mac = prefs.getString(_prefsKeyLastMac);
    if (mac == null || mac.isEmpty) return false;
    final name = prefs.getString(_prefsKeyLastName) ?? '';
    // Sambung langsung by MAC (scan hanya fallback) — lihat _ensureConnectedToMac.
    return _ensureConnectedToMac(mac, name: name);
  }

  Future<void> disconnect() async {
    if (!isSupported) return;
    try {
      await BluetoothPrintPlus.disconnect();
    } catch (e) {
      debugPrint('PrinterService.disconnect error: $e');
    } finally {
      _connectedDevice = null;
    }
  }

  Future<bool> printBytes(List<int> bytes) =>
      _synchronized(() => _printBytesLocked(bytes));

  Future<bool> _printBytesLocked(List<int> bytes) async {
    if (!isSupported) return false;
    if (!isConnected) {
      final ok = await tryAutoReconnect();
      if (!ok) return false;
    }
    try {
      // Reset printer (ESC @) di awal → buang sisa state (bold/align/font/
      // codepage) dari cetakan sebelumnya. Penyebab utama output tak konsisten.
      final data = Uint8List.fromList(<int>[0x1B, 0x40, ...bytes]);
      // Chunk kecil + jeda: buffer printer thermal BT kecil; kirim terlalu cepat
      // → byte ke-drop → teks misalign/kepotong. Jeda ~30ms per chunk.
      const chunkSize = 200;
      for (var i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final written = await BluetoothPrintPlus.write(data.sublist(i, end));
        if (written != true) return false;
        await Future.delayed(const Duration(milliseconds: 30));
      }
      return true;
    } catch (e) {
      debugPrint('PrinterService.printBytes error: $e');
      return false;
    }
  }

  // ── Registry multi-printer (Fase 3) ───────────────────────────────────────
  /// Daftar printer tersimpan.
  Future<List<SavedPrinter>> listPrinters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyPrinters);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(SavedPrinter.fromMap)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _savePrinters(List<SavedPrinter> printers) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _prefsKeyPrinters,
      jsonEncode(printers.map((p) => p.toMap()).toList()),
    );
    if (!saved) {
      throw StateError('Registry printer gagal disimpan');
    }
  }

  // addPrinter/addLanPrinter dihapus (yatim): keduanya tak pernah dipanggil.
  // Ironisnya justru merekalah yang men-dedup berdasarkan alamat fisik dengan
  // benar, sementara alur "Tambah Perangkat" yang HIDUP memakai savePrinter
  // yang dulu men-dedup id saja — itulah asal printer ganda. Dedup-nya kini
  // sudah pindah ke savePrinter, jadi keduanya benar-benar tak bersisa guna.

  Future<void> removePrinter(String id) async {
    final all = await listPrinters();
    final gone = all.where((p) => p.id == id).firstOrNull;
    final printers = all.where((p) => p.id != id).toList();
    await _savePrinters(printers);

    // Lupakan juga jejak last-MAC printer ini. Tanpa ini, menghapus printer
    // terakhir membuat registry kosong → printReceiptBytes jatuh ke jalur
    // legacy → tryAutoReconnect menyambung ulang ke MAC yang BARU SAJA
    // dihapus, dan struk tetap keluar dari printer yang user kira sudah pergi.
    if (gone != null && gone.mac.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_prefsKeyLastMac) == gone.mac) {
        await prefs.remove(_prefsKeyLastMac);
        await prefs.remove(_prefsKeyLastName);
      }
      if (_connectedDevice?.address == gone.mac) await disconnect();
    }

    // Bersihkan referensi default yang menunjuk printer ini.
    if ((await defaultPrinterId()) == id) {
      await setDefaultPrinter(printers.isNotEmpty ? printers.first.id : null);
    }
  }

  /// Perbarui properti printer.
  Future<void> updatePrinter(
    String id, {
    String? name,
    String? paper,
    int? copies,
    String? driver,
    bool? terpusat,
    bool? autoOrder,
    bool? autoQrOrder,
    bool? autoBayar,
    bool? autoVoid,
    bool? strukAutoOrder,
    bool? strukAutoBayar,
    List<String>? categories,
    String? printMode,
    String? headerLabel,
  }) async {
    final printers = (await listPrinters())
        .map(
          (p) => p.id == id
              ? p.copyWith(
                  name: name,
                  paper: paper,
                  copies: copies,
                  driver: driver,
                  terpusat: terpusat,
                  autoOrder: autoOrder,
                  autoQrOrder: autoQrOrder,
                  autoBayar: autoBayar,
                  autoVoid: autoVoid,
                  strukAutoOrder: strukAutoOrder,
                  strukAutoBayar: strukAutoBayar,
                  categories: categories,
                  printMode: printMode,
                  headerLabel: headerLabel,
                )
              : p,
        )
        .toList();
    await _savePrinters(printers);
  }

  /// Simpan (tambah/ganti) printer. Untuk wizard "Tambah Perangkat".
  ///
  /// Dedup berdasarkan ALAMAT FISIK (MAC untuk BT, host:port untuk LAN), bukan
  /// hanya id. Wizard membuat id baru dari timestamp tiap kali dijalankan, jadi
  /// dedup-by-id saja membuat satu printer fisik terdaftar berkali-kali bila
  /// user menambahkannya ulang — persis duplikat yang terlihat di daftar.
  /// Entri lama diganti: pengaturannya (peran, kertas, kategori) ikut terbawa
  /// ke id yang baru lewat referensi default & peta stasiun di bawah.
  Future<void> savePrinter(SavedPrinter printer) async {
    final all = await listPrinters();
    // Printer fisik yang SAMA (MAC/host:port) mungkin sudah terdaftar — mis.
    // user menambahkannya lagi untuk peran kedua (satu printer dipakai struk
    // DAN dapur). Dulu entri lama dibuang total → perannya + setelannya HILANG,
    // sehingga terlihat seperti "printer lama terhapus". Kini perannya
    // DIGABUNG ke entri yang disimpan, bukan ditimpa.
    var toSave = printer;
    for (final old in all.where(
      (p) => p.id != printer.id && _isSameDevice(p, printer),
    )) {
      toSave = toSave.copyWith(
        strukEnabled: toSave.strukEnabled || old.strukEnabled,
        dapurEnabled: toSave.dapurEnabled || old.dapurEnabled,
        autoOrder: toSave.autoOrder || old.autoOrder,
        autoQrOrder: toSave.autoQrOrder || old.autoQrOrder,
        autoBayar: toSave.autoBayar || old.autoBayar,
        autoVoid: toSave.autoVoid || old.autoVoid,
        // Toggle struk yang sudah dimatikan tidak boleh hidup kembali hanya
        // karena printer fisik yang sama ditambahkan untuk peran lain.
        strukAutoOrder: toSave.strukAutoOrder && old.strukAutoOrder,
        strukAutoBayar: toSave.strukAutoBayar && old.strukAutoBayar,
        // Kategori dapur & label header lama ikut terbawa bila entri baru belum
        // punya (mis. penambahan peran dari wizard yang defaultnya kosong).
        categories: toSave.categories.isEmpty
            ? old.categories
            : toSave.categories,
        headerLabel: toSave.headerLabel.isEmpty
            ? old.headerLabel
            : toSave.headerLabel,
        stationIds: toSave.effectiveStationIds.isEmpty
            ? old.effectiveStationIds
            : toSave.effectiveStationIds,
      );
    }
    final printers =
        all
            .where((p) => p.id != printer.id && !_isSameDevice(p, printer))
            .toList()
          ..add(toSave);
    await _savePrinters(printers);
    if ((await defaultPrinterId()) == null && printer.jenis == 'kasir') {
      await setDefaultPrinter(printer.id);
    }
    // Default yang menunjuk entri yang barusan tergantikan akan menggantung →
    // printerForReceipt() tak menemukannya. Arahkan ulang ke id baru.
    final def = await defaultPrinterId();
    if (def != null && await _printerById(def) == null) {
      await setDefaultPrinter(printer.id);
    }
  }

  /// Dua entri menunjuk printer FISIK yang sama? BT dibandingkan lewat MAC,
  /// LAN lewat host:port. Entri tanpa alamat (mis. data rusak) tak pernah cocok.
  bool _isSameDevice(SavedPrinter a, SavedPrinter b) {
    if (a.isLan != b.isLan) return false;
    if (a.isLan) {
      return a.host.isNotEmpty && a.host == b.host && a.port == b.port;
    }
    return a.mac.isNotEmpty && a.mac.toUpperCase() == b.mac.toUpperCase();
  }

  /// Printer berdasarkan jenis (kasir/dapur/dll).
  Future<List<SavedPrinter>> printersByJenis(String jenis) async =>
      (await listPrinters()).where((p) => p.jenis == jenis).toList();

  /// Printer untuk struk pelanggan: default bila peran Struk aktif, else printer
  /// ber-peran Struk pertama. null = tak ada printer struk yang aktif.
  Future<SavedPrinter?> printerForReceipt() async {
    final def = await _printerById(await defaultPrinterId());
    if (def != null && def.strukEnabled) return def;
    return (await listPrinters()).where((p) => p.strukEnabled).firstOrNull;
  }

  Future<PrinterHealth> checkHealth(SavedPrinter printer) async {
    final started = DateTime.now();
    if (printer.isLan) {
      if (printer.host.isEmpty) {
        return const PrinterHealth(
          status: PrinterHealthStatus.failed,
          message: 'IP printer belum diisi',
        );
      }
      Socket? socket;
      try {
        socket = await Socket.connect(
          printer.host,
          printer.port,
          timeout: const Duration(seconds: 3),
        );
        return PrinterHealth(
          status: PrinterHealthStatus.ready,
          latencyMs: DateTime.now().difference(started).inMilliseconds,
          message: 'LAN siap',
        );
      } catch (_) {
        return PrinterHealth(
          status: PrinterHealthStatus.failed,
          latencyMs: DateTime.now().difference(started).inMilliseconds,
          message: 'Tidak dapat terhubung ke ${printer.host}:${printer.port}',
        );
      } finally {
        try {
          await socket?.close();
          socket?.destroy();
        } catch (_) {}
      }
    }
    if (!isSupported) {
      return const PrinterHealth(
        status: PrinterHealthStatus.unsupported,
        message: 'Bluetooth hanya tersedia di Android',
      );
    }
    if (_connectedDevice?.address == printer.mac) {
      return PrinterHealth(
        status: PrinterHealthStatus.ready,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        message: 'Bluetooth siap',
      );
    }
    return const PrinterHealth(
      status: PrinterHealthStatus.disconnected,
      message: 'Bluetooth belum terhubung',
    );
  }

  /// Semua printer ber-peran Dapur aktif (multi-peran ala Majoo — printer yang
  /// sama boleh sekaligus jadi printer struk).
  Future<List<SavedPrinter>> kitchenPrinters() async =>
      (await listPrinters()).where((p) => p.dapurEnabled).toList();

  Future<String?> defaultPrinterId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKeyDefaultPrinter);
  }

  Future<void> setDefaultPrinter(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_prefsKeyDefaultPrinter);
      return;
    }
    await prefs.setString(_prefsKeyDefaultPrinter, id);
  }

  // Subsistem "peta stasiun → printer" dihapus seluruhnya (yatim).
  // Tak ada satu pun layar yang memanggil assignStationPrinter, jadi petanya
  // selalu kosong dan printerForStation/printStationBytes selalu jatuh ke
  // printer default — mereka tak pernah melakukan apa pun yang berbeda.
  // Perutean dapur yang SEBENARNYA dipakai berbasis kategori: kitchenPrinters()
  // + SavedPrinter.categories (lihat kitchen_print.dart).

  Future<SavedPrinter?> _printerById(String? id) async {
    if (id == null) return null;
    return (await listPrinters()).where((p) => p.id == id).firstOrNull;
  }

  /// Pastikan terhubung ke MAC tertentu (putus dulu bila beda printer).
  ///
  /// Sambung LANGSUNG lewat MAC — printer thermal BT klasik yang sudah di-pair
  /// sering TIDAK muncul lagi di hasil `startScan` (tak meng-advertise), jadi
  /// jalur lama "scan dulu, baru connect" gagal senyap saat autoprint (mis.
  /// order dari QR web). Scan hanya dipakai sebagai fallback.
  Future<bool> _ensureConnectedToMac(String mac, {String name = ''}) async {
    if (!isSupported || mac.isEmpty) return false;
    if (_connectedDevice?.address == mac) return true;
    if (_connectedDevice != null) await disconnect();

    // 1) Coba langsung by MAC (tanpa scan).
    if (await connect(BluetoothDevice(name, mac))) return true;

    // 2) Fallback: scan lalu connect (printer yang butuh discovery).
    List<BluetoothDevice> devices;
    try {
      devices = await scan(timeout: const Duration(seconds: 5));
    } catch (_) {
      return false;
    }
    final match = devices.where((d) => d.address == mac).firstOrNull;
    if (match == null) {
      debugPrint(
        'PrinterService: printer $mac tak ditemukan (pair & nyalakan?)',
      );
      return false;
    }
    return connect(match);
  }

  /// Apakah struk perlu koneksi Bluetooth aktif sebelum dicetak?
  ///
  /// Printer LAN mencetak lewat socket TCP — tak ada pairing, `isConnected`
  /// selamanya false untuknya. Pemanggil yang menggerbangi cetak dengan
  /// `if (!isConnected) ...` karena itu TAK PERNAH mencetak ke printer LAN dan
  /// malah memunculkan dialog scan Bluetooth. Tanya fungsi ini dulu.
  Future<bool> receiptNeedsBluetoothConnect() async {
    final printers = await listPrinters();
    if (printers.isEmpty) return true; // jalur legacy 1-printer = Bluetooth
    final rcpt = await printerForReceipt();
    if (rcpt == null) {
      return false; // tak ada printer struk → tak ada yg disambung
    }
    return !rcpt.isLan;
  }

  /// Cetak ke printer kasir/default (struk pelanggan). Fallback: printer terhubung
  /// / terakhir dipakai (kompatibel setup 1 printer).
  /// [auto] = dipicu otomatis (pembayaran). Autoprint dihormati per printer
  /// (toggle "Autoprint Bayar" tab Struk); cetak manual selalu jalan.
  ///
  /// Mengembalikan [PrintOutcome], BUKAN bool: "dilewati karena autoprint mati"
  /// harus bisa dibedakan dari "berhasil dicetak". Dulu keduanya sama-sama
  /// `true`, sehingga pemanggil menandai struk sebagai sudah-dicetak padahal
  /// tak pernah keluar — dan batas cetak lalu memblokir cetak ulangnya.
  Future<PrintOutcome> printReceiptBytes(
    List<int> bytes, {
    bool auto = false,
    String jobLabel = 'Struk',
    bool enqueueOnFailure = true,
    String requestId = '',
    String intent = 'receipt',
  }) async {
    final printers = await listPrinters();
    // Setup lama tanpa registry printer → jalur 1-printer (terhubung/terakhir).
    if (printers.isEmpty) {
      return (await printBytes(bytes))
          ? PrintOutcome.printed
          : PrintOutcome.failed;
    }
    final rcpt = await printerForReceipt();
    if (rcpt == null) {
      return PrintOutcome.skipped; // tak ada printer struk aktif
    }
    if (auto && !rcpt.strukAutoBayar) return PrintOutcome.skipped;
    return (await _printTo(
          rcpt,
          bytes,
          jobLabel: jobLabel,
          enqueueOnFailure: enqueueOnFailure,
          requestId: requestId,
          intent: intent,
        ))
        ? PrintOutcome.printed
        : PrintOutcome.failed;
  }

  /// Cetak struk ketika self-order web baru diterima. Ini bukan trigger
  /// pembayaran, sehingga tidak boleh ikut dimatikan oleh `Autoprint Bayar`.
  /// Tetap mensyaratkan peran Struk aktif pada printer.
  Future<PrintOutcome> printIncomingOrderReceiptBytes(List<int> bytes) async {
    final printers = await listPrinters();
    if (printers.isEmpty) {
      return (await printBytes(bytes))
          ? PrintOutcome.printed
          : PrintOutcome.failed;
    }
    final rcpt = await printerForReceipt();
    if (rcpt == null) return PrintOutcome.skipped;
    if (!rcpt.strukAutoOrder) return PrintOutcome.skipped;
    return (await _printTo(rcpt, bytes, jobLabel: 'Struk order online'))
        ? PrintOutcome.printed
        : PrintOutcome.failed;
  }

  /// Sambungkan ke satu printer tersimpan (BT: connect by MAC; LAN: tak perlu
  /// pairing). Dipakai tombol "Hubungkan" di UI. Tidak mengubah logika lain.
  Future<bool> connectPrinter(SavedPrinter p) async {
    if (p.isLan) return true;
    return _ensureConnectedToMac(p.mac, name: p.name);
  }

  /// Cetak langsung ke printer tertentu berdasarkan id.
  Future<bool> printToPrinterId(
    String printerId,
    List<int> bytes, {
    String? kitchenOrderId,
    String? kitchenDeviceId,
    int? copiesOverride,
    bool enqueueOnFailure = true,
    String requestId = '',
    String intent = 'kitchen',
  }) async {
    final p = await _printerById(printerId);
    if (p == null) return false;
    return _printTo(
      p,
      bytes,
      jobLabel: 'Tiket dapur',
      kitchenOrderId: kitchenOrderId,
      kitchenDeviceId: kitchenDeviceId,
      copiesOverride: copiesOverride,
      enqueueOnFailure: enqueueOnFailure,
      requestId: requestId,
      intent: intent,
    );
  }

  /// Dispatch cetak sesuai jenis printer (LAN socket vs Bluetooth), ulangi
  /// sesuai jumlah salinan printer.
  Future<bool> _printTo(
    SavedPrinter p,
    List<int> bytes, {
    bool enqueueOnFailure = true,
    String jobLabel = 'Cetak',
    String? kitchenOrderId,
    String? kitchenDeviceId,
    int? copiesOverride,
    String requestId = '',
    String intent = 'unknown',
  }) => _synchronized(
    () => _printToLocked(
      p,
      bytes,
      enqueueOnFailure: enqueueOnFailure,
      jobLabel: jobLabel,
      kitchenOrderId: kitchenOrderId,
      kitchenDeviceId: kitchenDeviceId,
      copiesOverride: copiesOverride,
      requestId: requestId,
      intent: intent,
    ),
  );

  Future<bool> _printToLocked(
    SavedPrinter p,
    List<int> bytes, {
    bool enqueueOnFailure = true,
    String jobLabel = 'Cetak',
    String? kitchenOrderId,
    String? kitchenDeviceId,
    int? copiesOverride,
    String requestId = '',
    String intent = 'unknown',
  }) async {
    final copies = (copiesOverride ?? p.copies).clamp(1, 5);
    var sentCopies = 0;
    for (var i = 0; i < copies; i++) {
      debugPrint(
        'PRINT_SEND request=$requestId intent=$intent target=${p.id} '
        'copy=${i + 1}/$copies timestamp=${DateTime.now().toIso8601String()}',
      );
      final sent = await _sendOnce(p, bytes);
      if (!sent) break; // gagal → hentikan sisa salinan
      sentCopies++;
    }
    if (sentCopies < copies && enqueueOnFailure) {
      await _enqueuePrintJob(
        p,
        bytes,
        jobLabel,
        'Koneksi printer gagal',
        copies: copies - sentCopies,
        kitchenOrderId: kitchenOrderId,
        kitchenDeviceId: kitchenDeviceId,
        requestId: requestId,
        intent: intent,
      );
    }
    return sentCopies == copies;
  }

  Future<bool> _sendOnce(SavedPrinter p, List<int> bytes) async {
    final testSender = _physicalSenderForTest;
    if (testSender != null) return testSender(p, bytes);
    if (p.isLan) return _writeBytesLan(p.host, p.port, bytes);
    return (await _ensureConnectedToMac(p.mac, name: p.name)) &&
        await _writeBytes(bytes);
  }

  /// Cetak ke printer jaringan (ESC/POS via socket TCP, default port 9100).
  /// Tidak butuh Bluetooth — jalan di semua platform.
  Future<bool> _writeBytesLan(String host, int port, List<int> bytes) async {
    if (host.isEmpty) return false;
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(bytes);
      await socket.flush();
      return true;
    } catch (e) {
      debugPrint('PrinterService._writeBytesLan error: $e');
      return false;
    } finally {
      try {
        await socket?.close();
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Tes cetak ke satu printer (dipakai di UI registry).
  Future<bool> testPrintTo(SavedPrinter p, List<int> bytes) =>
      _printTo(p, bytes, enqueueOnFailure: false, jobLabel: 'Tes printer');

  /// Tulis byte ke printer yang SEDANG terhubung (asumsi sudah connect).
  Future<bool> _writeBytes(List<int> bytes) async {
    if (!isSupported || !isConnected) return false;
    try {
      // Reset printer (ESC @) di awal → buang sisa state (bold/align/font/
      // codepage) dari cetakan sebelumnya. Penyebab utama output tak konsisten.
      final data = Uint8List.fromList(<int>[0x1B, 0x40, ...bytes]);
      // Chunk kecil + jeda: buffer printer thermal BT kecil; kirim terlalu cepat
      // → byte ke-drop → teks misalign/kepotong. Jeda ~30ms per chunk.
      const chunkSize = 200;
      for (var i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final written = await BluetoothPrintPlus.write(data.sublist(i, end));
        if (written != true) return false;
        await Future.delayed(const Duration(milliseconds: 30));
      }
      return true;
    } catch (e) {
      debugPrint('PrinterService._writeBytes error: $e');
      return false;
    }
  }

  // lastUsedPrinter/forgetPrinter dihapus (yatim): tak ada pemanggil. Melupakan
  // printer kini menjadi tanggung jawab removePrinter, yang memang tahu MAC
  // mana yang harus ikut dilupakan.
}

extension _IterableHelper<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Printer tersimpan di registry (device-local).
/// `type`: 'bt' (Bluetooth, pakai `mac`) atau 'lan' (jaringan, pakai `host:port`).
class SavedPrinter {
  final String id;
  final String name;
  final String mac;
  final String type; // koneksi: 'bt' | 'lan' | 'usb'
  final String host; // IP untuk LAN
  final int port; // port LAN (default 9100)
  final String paper; // '58' | '80' (mm)
  final int copies; // jumlah salinan per cetak
  // Model device-centric ala Majoo:
  final String jenis; // 'kasir'|'dapur'|'label'|'alamat'|'terpusat'|'scanner'
  final String driver; // tipe driver (mis. 'generic1')
  final bool terpusat; // Printer Terpusat
  final bool autoOrder; // Autoprint saat order disimpan/kirim ke dapur
  final bool autoQrOrder; // Autoprint tiket dapur saat pesanan QR masuk
  final bool autoBayar; // Autoprint saat pembayaran
  final bool autoVoid; // Autoprint saat void
  final List<String> categories; // kategori yang dicetak (untuk jenis dapur)
  final String printMode; // 'pisah' | 'gabung'
  final bool
  enabled; // legacy master-switch (dipertahankan utk migrasi data lama)
  // Label header tiket dapur (mis. "Dapur - Bar"). Kosong → pakai nama printer.
  final String headerLabel;

  /// ID stasiun outlet dari owner-panel. Kosong = gunakan mapping kategori
  /// lokal lama untuk kompatibilitas printer yang belum di-bind. `stationId`
  /// dipertahankan untuk membaca data lama; data baru memakai `stationIds`.
  final String stationId;
  final List<String> stationIds;
  // ── Multi-peran ala Majoo: tiap tab punya toggle sendiri ────────────────────
  final bool strukEnabled; // tab Struk: printer ini mencetak struk pelanggan
  final bool dapurEnabled; // tab Dapur: printer ini mencetak tiket dapur
  final bool strukAutoOrder; // tab Struk: autoprint saat order QR masuk
  final bool strukAutoBayar; // tab Struk: autoprint struk saat pembayaran

  const SavedPrinter({
    required this.id,
    required this.name,
    this.mac = '',
    this.type = 'bt',
    this.host = '',
    this.port = 9100,
    this.paper = '58',
    this.copies = 1,
    this.jenis = 'kasir',
    this.driver = 'generic1',
    this.terpusat = false,
    this.autoOrder = false,
    this.autoQrOrder = false,
    this.autoBayar = false,
    this.autoVoid = false,
    this.categories = const [],
    this.printMode = 'gabung',
    this.enabled = true,
    this.headerLabel = '',
    this.stationId = '',
    this.stationIds = const [],
    this.strukEnabled = true,
    this.dapurEnabled = false,
    this.strukAutoOrder = true,
    this.strukAutoBayar = true,
  });

  bool get isLan => type == 'lan';
  bool get isKitchen => dapurEnabled;
  List<String> get effectiveStationIds {
    final ids = stationIds
        .where((id) => id.trim().isNotEmpty)
        .map((id) => id.trim())
        .toSet()
        .toList();
    if (ids.isNotEmpty) return ids;
    return stationId.trim().isEmpty ? const [] : [stationId.trim()];
  }

  SavedPrinter copyWith({
    String? mac,
    String? type,
    String? host,
    int? port,
    String? name,
    String? paper,
    int? copies,
    String? jenis,
    String? driver,
    bool? terpusat,
    bool? autoOrder,
    bool? autoQrOrder,
    bool? autoBayar,
    bool? autoVoid,
    List<String>? categories,
    String? printMode,
    bool? enabled,
    String? headerLabel,
    String? stationId,
    List<String>? stationIds,
    bool? strukEnabled,
    bool? dapurEnabled,
    bool? strukAutoOrder,
    bool? strukAutoBayar,
  }) => SavedPrinter(
    id: id,
    name: name ?? this.name,
    mac: mac ?? this.mac,
    type: type ?? this.type,
    host: host ?? this.host,
    port: port ?? this.port,
    paper: paper ?? this.paper,
    copies: copies ?? this.copies,
    jenis: jenis ?? this.jenis,
    driver: driver ?? this.driver,
    terpusat: terpusat ?? this.terpusat,
    autoOrder: autoOrder ?? this.autoOrder,
    autoQrOrder: autoQrOrder ?? this.autoQrOrder,
    autoBayar: autoBayar ?? this.autoBayar,
    autoVoid: autoVoid ?? this.autoVoid,
    categories: categories ?? this.categories,
    printMode: printMode ?? this.printMode,
    enabled: enabled ?? this.enabled,
    headerLabel: headerLabel ?? this.headerLabel,
    stationId: stationId ?? this.stationId,
    stationIds: stationIds ?? this.stationIds,
    strukEnabled: strukEnabled ?? this.strukEnabled,
    dapurEnabled: dapurEnabled ?? this.dapurEnabled,
    strukAutoOrder: strukAutoOrder ?? this.strukAutoOrder,
    strukAutoBayar: strukAutoBayar ?? this.strukAutoBayar,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'mac': mac,
    'type': type,
    'host': host,
    'port': port,
    'paper': paper,
    'copies': copies,
    'jenis': jenis,
    'driver': driver,
    'terpusat': terpusat,
    'autoOrder': autoOrder,
    'autoQrOrder': autoQrOrder,
    'autoBayar': autoBayar,
    'autoVoid': autoVoid,
    'categories': categories,
    'printMode': printMode,
    'enabled': enabled,
    'headerLabel': headerLabel,
    'stationId': stationId,
    'stationIds': effectiveStationIds,
    'strukEnabled': strukEnabled,
    'dapurEnabled': dapurEnabled,
    'strukAutoOrder': strukAutoOrder,
    'strukAutoBayar': strukAutoBayar,
  };

  factory SavedPrinter.fromMap(Map<String, dynamic> m) {
    final jenis = m['jenis'] as String? ?? 'kasir';
    final enabled = m['enabled'] as bool? ?? true;
    final copies = (m['copies'] as num?)?.toInt() ?? 1;
    return SavedPrinter(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      mac: m['mac'] as String? ?? '',
      type: m['type'] as String? ?? 'bt',
      host: m['host'] as String? ?? '',
      port: (m['port'] as num?)?.toInt() ?? 9100,
      paper: m['paper'] as String? ?? '58',
      copies: copies,
      jenis: jenis,
      driver: m['driver'] as String? ?? 'generic1',
      terpusat: m['terpusat'] as bool? ?? false,
      autoOrder: m['autoOrder'] as bool? ?? false,
      // Default mati agar pembaruan pada outlet dengan beberapa kasir tidak
      // langsung membuat semua perangkat mencetak order QR yang sama.
      autoQrOrder: m['autoQrOrder'] as bool? ?? false,
      autoBayar: m['autoBayar'] as bool? ?? false,
      autoVoid: m['autoVoid'] as bool? ?? false,
      categories:
          (m['categories'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      printMode: m['printMode'] as String? ?? 'gabung',
      enabled: enabled,
      headerLabel: m['headerLabel'] as String? ?? '',
      stationId: m['stationId'] as String? ?? '',
      stationIds:
          (m['stationIds'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      // Migrasi data lama (single-role `jenis`) → peran per-tab.
      strukEnabled: m['strukEnabled'] as bool? ?? (jenis != 'dapur' && enabled),
      dapurEnabled: m['dapurEnabled'] as bool? ?? (jenis == 'dapur' && enabled),
      strukAutoOrder: m['strukAutoOrder'] as bool? ?? true,
      strukAutoBayar: m['strukAutoBayar'] as bool? ?? true,
    );
  }
}

/// Izin Bluetooth (scan/connect/location) ditolak user.
class PrinterPermissionException implements Exception {
  const PrinterPermissionException();
  @override
  String toString() => 'Izin Bluetooth ditolak';
}

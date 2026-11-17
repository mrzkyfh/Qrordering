import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/order.dart';
import 'printer_service.dart';
import 'order_realtime_service.dart';
import 'receipt_builder.dart';
import 'kitchen_print.dart';
import 'error_log_service.dart';
import 'keep_alive_service.dart';
import 'connectivity_service.dart';
import '../../features/settings/data/app_settings.dart';

/// Service yang memantau order baru (self-order) yang masuk via realtime
/// dan menampilkan notifikasi sistem + suara untuk kasir/manajer/admin.
///
/// Pemakaian:
/// ```dart
/// final notif = NotificationService();
/// await notif.init();
/// notif.startWatching(outletId);
///
/// // Listen banner di UI:
/// notif.events.listen((event) { ... });
///
/// // Saat logout / dispose:
/// notif.stop();
/// ```
class NotificationService with WidgetsBindingObserver {
  NotificationService._();
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  final _plugin = FlutterLocalNotificationsPlugin();
  // Player untuk nada dering saat app di depan (foreground). Notifikasi sistem
  // memutar suaranya sendiri lewat channel saat background.
  final AudioPlayer _sfx = AudioPlayer(playerId: 'order_alert');
  final _eventController = StreamController<NewOrderEvent>.broadcast();
  StreamSubscription? _realtimeSub;
  String? _currentOutletId;
  bool _initialized = false;
  Future<void>? _initializing;
  Timer? _bootstrapTimer;
  Timer? _pendingRecoveryTimer;
  DateTime? _nextBackgroundPollAt;
  Duration _backgroundPollDelay = const Duration(seconds: 60);
  bool _lifecycleObserverAttached = false;
  bool _requestingNotificationPermission = false;
  bool _notificationPermissionHandled = false;
  bool _silenceBootstrap = true;
  DateTime _watchStartedAt = DateTime.now();
  // Waktu event rows terakhir diterima. Saat channel putus lalu tersambung
  // ulang, snapshot pertama dipakai untuk MEMULIHKAN order yang masuk selama
  // koneksi mati (order setelah _lastRowsAt) — bukan hanya order < 60 detik.
  DateTime _lastRowsAt = DateTime.now();
  // Apakah aplikasi sedang di depan (terlihat). Saat foreground, order baru
  // cukup ditampilkan lewat banner in-app → notifikasi sistem DITEKAN agar tidak
  // dobel (banner + notif tray untuk satu order yang sama). Saat background,
  // sebaliknya: banner tak terlihat, jadi notifikasi sistem yang dipakai.
  // Default false penting untuk FlutterEngine headless milik foreground
  // service: tanpa Activity, tidak akan ada event `paused` untuk mengubah true.
  bool _isForeground = false;
  bool _pendingRecoveryInProgress = false;
  DateTime? _lastPendingRecoveryAt;
  bool _connectivityListenerAttached = false;
  bool _stopping = false;
  final Set<Future<void>> _orderChangeTasks = {};

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (_isForeground) {
      // Engine dapat tetap hidup tanpa Activity karena foreground service.
      // Minta izin hanya setelah Activity terpasang kembali.
      unawaited(_requestNotificationPermissionIfPossible());
      unawaited(PrinterService().retryPendingPrintJobs());
      unawaited(_recoverPendingKitchenTickets());
    }
  }

  /// Stream notifikasi order baru — UI listen untuk tampilkan banner.
  Stream<NewOrderEvent> get events => _eventController.stream;

  // Channel v2: dua varian agar toggle "Notifikasi Suara" tetap dihormati di
  // Android 8+ (suara channel dikunci saat dibuat; per-notifikasi diabaikan).
  // ID baru (bukan 'new_orders_channel' lama) supaya nada dering kustom benar-
  // benar terpakai di perangkat yang sudah pernah membuat channel lama.
  static const _channelSound = 'new_orders_v2_sound';
  static const _channelSilent = 'new_orders_v2_silent';
  static const _channelName = 'Pesanan Baru';
  static const _channelDesc = 'Notifikasi saat pesanan dari pelanggan masuk';
  // Nama file di android/app/src/main/res/raw/order_alert.wav (tanpa ekstensi).
  static const _soundResource = 'order_alert';
  // Aset untuk pemutaran foreground (relatif ke folder assets/).
  static const _soundAsset = 'audio/order_alert.wav';

  /// Init plugin dan channel notifikasi. Aman juga untuk engine headless.
  ///
  /// Permission Android 13+ diminta terpisah hanya ketika Activity sedang
  /// `resumed`. `flutter_local_notifications` mengakses Activity saat request;
  /// pada engine yang dipertahankan foreground service Activity bisa null.
  Future<void> init() {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    // Pantau lifecycle untuk membedakan foreground vs background (anti-dobel).
    if (!_lifecycleObserverAttached) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverAttached = true;
    }
    _isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: iosInit,
      ),
    );

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Buat channel eksplisit dengan nada dering kustom. Suara sebuah channel
    // TIDAK bisa diubah setelah dibuat → kita pakai dua channel: bersuara &
    // senyap, dipilih sesuai preferensi. Channel lama 'new_orders_channel'
    // dihapus agar tidak menyisakan channel default di daftar sistem.
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelSound,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(_soundResource),
        enableVibration: true,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelSilent,
        '$_channelName (senyap)',
        description: _channelDesc,
        importance: Importance.high,
        playSound: false,
        enableVibration: true,
      ),
    );
    await androidImpl?.deleteNotificationChannel(
      channelId: 'new_orders_channel',
    );

    _initialized = true;
    await _requestNotificationPermissionIfPossible();
  }

  /// Android 13+ membutuhkan POST_NOTIFICATIONS dan API plugin ini memerlukan
  /// Activity. Jangan panggil ketika engine berjalan headless/detached.
  ///
  /// Jika Activity terlepas tepat di antara pengecekan lifecycle dan platform
  /// call, exception ditahan dan request dicoba lagi pada event `resumed`
  /// berikutnya. Hasil `false` tetap dianggap sudah ditangani agar dialog tidak
  /// dimunculkan berulang kali dalam satu proses setelah pengguna menolak.
  Future<void> _requestNotificationPermissionIfPossible() async {
    if (!_initialized ||
        !_isForeground ||
        _notificationPermissionHandled ||
        _requestingNotificationPermission) {
      return;
    }

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidImpl == null) return;

    _requestingNotificationPermission = true;
    try {
      await androidImpl.requestNotificationsPermission();
      _notificationPermissionHandled = true;
    } catch (error) {
      // Lifecycle bisa berubah sesudah `_isForeground` diperiksa. Ini bukan
      // fatal: channel/notifikasi background tetap terinisialisasi, dan request
      // permission akan dicoba lagi saat Activity kembali `resumed`.
      debugPrint(
        'NotificationService: notification permission deferred ($error)',
      );
    } finally {
      _requestingNotificationPermission = false;
    }
  }

  /// Mulai subscribe ke channel orders untuk outlet ini.
  /// Aman dipanggil ulang — akan unsubscribe channel lama dulu.
  Future<void> startWatching(String outletId) async {
    if (outletId.isEmpty) return;
    if (_currentOutletId == outletId && _realtimeSub != null) return;

    // `stop()` asynchronous karena menunggu subscription lama dibatalkan.
    // Wajib ditunggu sebelum outlet baru disimpan; sebelumnya lanjutan stop()
    // berjalan belakangan dan mengosongkan `_currentOutletId` tepat ketika
    // order masuk, sehingga autoprint selalu menerima outlet kosong.
    await stop();
    _stopping = false;
    unawaited(PrinterService().retryPendingPrintJobs());
    _currentOutletId = outletId;
    if (!_connectivityListenerAttached) {
      ConnectivityService.instance.online.addListener(
        _recoverPendingWhenOnline,
      );
      _connectivityListenerAttached = true;
    }
    KeepAliveService.instance.onBackgroundTick = _pollLatestOrders;
    _silenceBootstrap = true; // jangan bunyikan event dari snapshot awal

    _watchStartedAt = DateTime.now();
    _lastRowsAt = _watchStartedAt;
    _nextBackgroundPollAt = null;
    _backgroundPollDelay = const Duration(seconds: 60);
    // Satu feed bersama dipakai pula oleh badge dan halaman Daftar Order.
    // Retry koneksi ditangani terpusat oleh OrderRealtimeService.
    _realtimeSub = OrderRealtimeService.instance
        .watch(outletId)
        .listen((rows) => unawaited(_onOrdersChanged(rows)));

    // Pulihkan semua self-order aktif yang server tandai belum tercetak.
    // Tidak dibatasi usia/50 row; klaim atomik DB mencegah cetak ganda.
    unawaited(_recoverPendingKitchenTickets(force: true));

    // Bootstrap event pertama (snapshot row existing) tidak kita anggap sebagai
    // "order baru" — silence selama 2 detik pertama.
    _bootstrapTimer?.cancel();
    _bootstrapTimer = Timer(const Duration(seconds: 2), () {
      _bootstrapTimer = null;
      _silenceBootstrap = false;
    });
  }

  bool _pollInProgress = false;

  void _recoverPendingWhenOnline() {
    if (!_stopping && ConnectivityService.instance.online.value) {
      unawaited(_recoverPendingKitchenTickets(force: true));
    }
  }

  void _schedulePendingRecovery({Duration delay = const Duration(minutes: 2)}) {
    if (_stopping || _pendingRecoveryTimer?.isActive == true) return;
    _pendingRecoveryTimer = Timer(delay, () {
      _pendingRecoveryTimer = null;
      unawaited(_recoverPendingKitchenTickets(force: true));
    });
  }

  Future<void> _recoverPendingKitchenTickets({bool force = false}) async {
    final outletId = _currentOutletId;
    if (outletId == null ||
        outletId.isEmpty ||
        _stopping ||
        _pendingRecoveryInProgress ||
        !PrinterService.isSupported ||
        !ConnectivityService.instance.online.value) {
      return;
    }

    _pendingRecoveryInProgress = true;
    try {
      // Tidak ada kemungkinan tiket keluar bila printer dapur belum disetel.
      // Hindari query seluruh pending order + claim/release setiap dua menit.
      final qrPrinters = (await PrinterService().kitchenPrinters())
          .where((printer) => printer.autoQrOrder)
          .toList();
      if (qrPrinters.isEmpty) {
        _pendingRecoveryTimer?.cancel();
        _pendingRecoveryTimer = null;
        // Hanya baca SharedPreferences lagi nanti; tidak ada request Supabase
        // sampai sebuah printer dapur benar-benar tersedia.
        _schedulePendingRecovery(delay: const Duration(minutes: 10));
        return;
      }
      final now = DateTime.now();
      if (!force && !pendingKitchenRecoveryIsDue(_lastPendingRecoveryAt, now)) {
        return;
      }
      _lastPendingRecoveryAt = now;
      const pageSize = 100;
      var from = 0;
      final pending = <Map<String, dynamic>>[];
      while (true) {
        final rows = await Supabase.instance.client
            .from('orders')
            .select(
              'id, outlet_id, order_type, status, created_at, order_number, table_id, total_amount',
            )
            .eq('outlet_id', outletId)
            .eq('order_type', 'self_order')
            .eq('kitchen_printed', false)
            .inFilter('status', const [
              'draft',
              'confirmed',
              'preparing',
              'ready',
              'served',
            ])
            .order('created_at')
            .range(from, from + pageSize - 1);
        final page = List<Map<String, dynamic>>.from(rows);
        pending.addAll(page);
        if (page.length < pageSize) break;
        from += pageSize;
      }
      if (pending.isNotEmpty) {
        await _onOrdersChanged(pending, recoverAllPending: true);
      }
    } catch (error, stack) {
      debugPrint('NotificationService pending recovery error: $error');
      await ErrorLogService.report(error, stack);
    } finally {
      _pendingRecoveryInProgress = false;
      // Realtime bisa terputus diam-diam saat aplikasi tetap di depan.
      // Pemindaian pending berkala mengambil tiket yang terlewat tanpa
      // mencetak ganda karena claim_kitchen_print atomik di server.
      if (!_stopping && _currentOutletId == outletId) {
        _schedulePendingRecovery();
      }
    }
  }

  /// Ambil sedikit overlap untuk menutup race antara perubahan row dan request,
  /// tetapi jangan pernah memindai lebih dari 10 menit riwayat.
  static DateTime _pollCutoff(DateTime now, DateTime lastRowsAt) {
    var cutoff = lastRowsAt.subtract(const Duration(seconds: 30));
    final earliest = now.subtract(const Duration(minutes: 10));
    if (cutoff.isBefore(earliest)) cutoff = earliest;
    return cutoff.toUtc();
  }

  static DateTime _eventCutoff(
    DateTime now,
    DateTime lastRowsAt, {
    required bool recoverAllPending,
  }) {
    if (recoverAllPending) return DateTime.fromMillisecondsSinceEpoch(0);
    var cutoff = lastRowsAt.subtract(const Duration(seconds: 30));
    final earliest = now.subtract(const Duration(minutes: 10));
    if (cutoff.isBefore(earliest)) cutoff = earliest;
    return cutoff;
  }

  /// Fallback OEM/background: beberapa perangkat menahan event WebSocket saat
  /// Activity pause meski foreground service tetap aktif. Native service tetap
  /// membangunkan Dart, tetapi request server di bawah dibatasi 30–300 detik.
  Future<void> _pollLatestOrders() async {
    final outletId = _currentOutletId;
    if (_isForeground ||
        outletId == null ||
        outletId.isEmpty ||
        _stopping ||
        _pollInProgress ||
        _silenceBootstrap) {
      return;
    }
    final now = DateTime.now();
    final nextPoll = _nextBackgroundPollAt;
    if (nextPoll != null && now.isBefore(nextPoll)) return;

    _pollInProgress = true;
    try {
      final rows = await Supabase.instance.client
          .from('orders')
          .select(
            'id, outlet_id, order_type, status, created_at, order_number, table_id, total_amount',
          )
          .eq('outlet_id', outletId)
          .gte(
            'created_at',
            _pollCutoff(DateTime.now(), _lastRowsAt).toIso8601String(),
          )
          .order('created_at', ascending: false)
          .limit(50);
      // Jangan selesaikan platform-channel tick sebelum seluruh notifikasi dan
      // proses cetak selesai. Jika Future dilepas (fire-and-forget), OPPO dapat
      // menidurkan isolate lagi di tengah proses, biasanya setelah fetch order.
      await _onOrdersChanged(List<Map<String, dynamic>>.from(rows));
      // WebSocket sehat tetap diperiksa sesekali karena beberapa OEM dapat
      // membekukannya tanpa mengirim error. Interval dua menit menekan API/log
      // query tanpa mengganggu jalur utama Realtime. Saat channel benar-benar
      // putus, gunakan 30 detik sampai tersambung kembali.
      _backgroundPollDelay = orderBackgroundPollDelay(
        realtimeHealthy: OrderRealtimeService.instance.isHealthy(outletId),
        requestFailed: false,
        previous: _backgroundPollDelay,
      );
      _nextBackgroundPollAt = DateTime.now().add(_backgroundPollDelay);
    } catch (e) {
      debugPrint('NotificationService background poll error: $e');
      _backgroundPollDelay = orderBackgroundPollDelay(
        realtimeHealthy: false,
        requestFailed: true,
        previous: _backgroundPollDelay,
      );
      _nextBackgroundPollAt = DateTime.now().add(_backgroundPollDelay);
    } finally {
      _pollInProgress = false;
    }
  }

  Future<void> _onOrdersChanged(
    List<Map<String, dynamic>> rows, {
    bool recoverAllPending = false,
  }) async {
    if (_stopping) return;
    final task = _processOrdersChanged(
      rows,
      recoverAllPending: recoverAllPending,
    );
    _orderChangeTasks.add(task);
    try {
      await task;
    } finally {
      _orderChangeTasks.remove(task);
    }
  }

  Future<void> _processOrdersChanged(
    List<Map<String, dynamic>> rows, {
    required bool recoverAllPending,
  }) async {
    final now = DateTime.now();
    // Window order yang dianggap "baru": sejak event terakhir (dikurangi buffer
    // 30 detik), maksimal 10 menit ke belakang. Dengan ini, order yang masuk
    // SELAMA channel putus tetap ternotif & tercetak begitu tersambung ulang
    // (snapshot reconnect memuatnya) — bukan hanya order < 60 detik. Batas 10
    // menit mencegah re-notif/re-print order lama yang keluar dari dedup set.
    var cutoff = _eventCutoff(
      now,
      _lastRowsAt,
      recoverAllPending: recoverAllPending,
    );
    final earliest = now.subtract(const Duration(minutes: 10));
    if (_silenceBootstrap && !recoverAllPending) cutoff = earliest;
    _lastRowsAt = now;

    // Cari order self_order baru dalam window. Order web kini masuk sebagai
    // 'draft' (dulu 'confirmed') → terima keduanya.
    for (final row in rows) {
      final type = row['order_type'] as String?;
      final status = row['status'] as String?;
      final createdAtStr = row['created_at'] as String?;
      final recoverableStatus = const {
        'draft',
        'confirmed',
        'preparing',
        'ready',
        'served',
      }.contains(status);
      if (type != 'self_order' ||
          (recoverAllPending
              ? !recoverableStatus
              : (status != 'draft' && status != 'confirmed')) ||
          createdAtStr == null) {
        continue;
      }

      final createdAt = DateTime.tryParse(createdAtStr);
      if (createdAt == null) continue;
      // Recovery eksplisit memindai seluruh tiket aktif yang belum diakui
      // server. Prosesnya senyap; lease server mencegah cetak ganda.
      final bootstrapRecovery =
          recoverAllPending ||
          (_silenceBootstrap && createdAt.isBefore(_watchStartedAt));
      final orderId = row['id'] as String? ?? '';
      final kitchenPending =
          _recentlyNotified.contains(orderId) &&
          !_kitchenPrintCompleted.contains(orderId);
      if (!recoverAllPending && createdAt.isBefore(cutoff) && !kitchenPending) {
        continue;
      }

      // Notifikasi hanya sekali, tetapi tiket dapur yang gagal/belum memiliki
      // item harus tetap dapat dicoba pada snapshot berikutnya.
      final firstSeen = _recentlyNotified.add(orderId);
      if (!firstSeen && !kitchenPending && !recoverAllPending) continue;
      if (!_ordersBeingProcessed.add(orderId)) continue;

      try {
        final orderNumber = row['order_number'] as String? ?? '—';
        final tableId = row['table_id'] as String?;
        final totalAmount = (row['total_amount'] as num?)?.toDouble() ?? 0;

        if (firstSeen && !bootstrapRecovery) {
          try {
            if (!_isForeground) {
              await _showSystemNotification(orderNumber, totalAmount);
            } else {
              await _playForegroundChime();
            }
          } catch (error) {
            debugPrint('NotificationService alert warning: $error');
          }
          _eventController.add(
            NewOrderEvent(
              orderId: orderId,
              orderNumber: orderNumber,
              tableId: tableId,
              totalAmount: totalAmount,
              receivedAt: now,
            ),
          );
        }

        final orderOutletId =
            row['outlet_id'] as String? ?? _currentOutletId ?? '';
        final result = await _autoPrintReceipt(
          orderId,
          orderOutletId,
          printReceipt: firstSeen && !bootstrapRecovery,
        );
        if (!kitchenPrintNeedsRecovery(result)) {
          _kitchenPrintCompleted.add(orderId);
        } else {
          // Data belum lengkap atau lease masih dipegang perangkat yang
          // kemudian bisa mati. Pindai ulang setelah jeda; konfigurasi tanpa
          // printer sudah ditangani sebagai skip final di helper di bawah.
          _schedulePendingRecovery();
        }
      } catch (error, stack) {
        debugPrint('NotificationService order $orderId print error: $error');
        await ErrorLogService.report(error, stack);
        _schedulePendingRecovery();
      } finally {
        _ordersBeingProcessed.remove(orderId);
      }

      while (_recentlyNotified.length > 50) {
        final expired = _recentlyNotified.first;
        _recentlyNotified.remove(expired);
        _kitchenPrintCompleted.remove(expired);
      }
    }
  }

  final Set<String> _recentlyNotified = {};
  final Set<String> _kitchenPrintCompleted = {};
  final Set<String> _ordersBeingProcessed = {};

  /// Cetak struk order web secara otomatis saat masuk. Karena masih draft
  /// (belum bayar), struk diberi penanda jelas dan tanpa baris pembayaran.
  /// Best-effort: diam bila bukan Android / printer tak tersambung / gagal.
  Future<KitchenPrintResult?> _autoPrintReceipt(
    String orderId,
    String outletId, {
    required bool printReceipt,
  }) async {
    if (!PrinterService.isSupported || orderId.isEmpty || outletId.isEmpty) {
      return null;
    }
    // Tiket dapur didahulukan. Klaim server mencegah dua tablet mencetak order
    // QR yang sama; klaim dilepas bila belum berhasil dicetak/diantrekan.
    KitchenPrintResult? kitchenResult;
    if ((await PrinterService().kitchenPrinters()).isEmpty) {
      kitchenResult = const KitchenPrintResult(
        skippedReason: 'Belum ada printer Dapur yang aktif',
      );
      _schedulePendingRecovery(delay: const Duration(minutes: 10));
    } else {
      try {
        kitchenResult = await printKitchenTicketsForOrder(
          orderId: orderId,
          outletId: outletId,
          trigger: KitchenTrigger.qrOrder,
          printedBy: 'Sistem',
          skipIfAlreadyPrinted: true,
          claimBeforePrint: true,
        );
      } catch (e) {
        debugPrint('NotificationService kitchen ticket error: $e');
        await ErrorLogService.report(e, StackTrace.current);
      }
    }

    // Struk kasir best-effort. JANGAN cek koneksi di sini — dulu digate
    //    `isConnected || tryAutoReconnect()` (jalur legacy last-MAC) sehingga
    //    printer LAN / printer registry yang belum tersambung di-skip diam-diam.
    //    printReceiptBytes → _printTo sudah mengurus koneksi sendiri
    //    (BT: scan+connect by MAC; LAN: socket langsung).
    //    Kegagalan di sini TIDAK boleh mem-skip tiket dapur di bawah.
    if (printReceipt) {
      try {
        final printer = PrinterService();
        final client = Supabase.instance.client;
        final orderData = await _fetchCompleteOrder(client, orderId);
        final order = Order.fromJson(orderData);

        final outletData = await client
            .from('outlets')
            .select('name, address, phone, city, settings')
            .eq('id', outletId)
            .single();
        final info = OutletReceiptInfo.fromMap(outletData);

        final rcpt = await printer.printerForReceipt();
        final paper = rcpt?.paper == '80' ? PaperSize.mm80 : PaperSize.mm58;
        final builder = ReceiptBuilder(
          outlet: info,
          paperSize: paper,
          driver: rcpt?.driver ?? 'generic1',
        );
        final bytes = await builder.build(
          order: order,
          customerName: order.customerName,
          documentTitle: 'ORDER QR - BELUM DIBAYAR',
        );
        final outcome = await printer.printIncomingOrderReceiptBytes(bytes);
        if (outcome.isFailed) {
          debugPrint(
            'NotificationService: struk order $orderId masuk antrean retry',
          );
        } else if (!outcome.isPrinted) {
          // Printer Struk nonaktif maupun autoprint yang dimatikan adalah
          // konfigurasi yang sah, bukan error.
          debugPrint(
            'NotificationService: autoprint order $orderId dilewati '
            '(printer Struk tidak aktif atau autoprint dimatikan)',
          );
        }
      } catch (e) {
        debugPrint('NotificationService._autoPrintReceipt error: $e');
        await ErrorLogService.report(e, StackTrace.current);
      }
    }

    return kitchenResult;
  }

  /// Event realtime untuk tabel `orders` bisa tiba beberapa saat sebelum web
  /// selesai memasukkan `order_items`. Tunggu data lengkap agar autoprint tidak
  /// menghasilkan struk kosong atau melewati tiket dapur secara diam-diam.
  Future<Map<String, dynamic>> _fetchCompleteOrder(
    SupabaseClient client,
    String orderId,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final data = await client
            .from('orders')
            .select(
              '*, restaurant_tables(table_number), order_items(*, menu_items(*), order_item_options(extra_name, option_name, price))',
            )
            .eq('id', orderId)
            .single();
        final items = data['order_items'];
        if (items is List && items.isNotEmpty) return data;
        lastError = StateError('order_items belum tersedia');
      } catch (e) {
        lastError = e;
      }
      if (attempt < 5) {
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
    throw StateError('Data order $orderId belum lengkap: $lastError');
  }

  /// Putar nada dering saat app di depan (foreground). BERULANG (loop) hingga
  /// kasir membuka/menutup pesanan → dihentikan lewat [stopAlertSound].
  /// Menghormati preferensi "Notifikasi Suara". Best-effort: diam bila gagal.
  Future<void> _playForegroundChime() async {
    if (!AppSettings.soundNotifEnabled) return;
    try {
      await _sfx.stop();
      await _sfx.setReleaseMode(ReleaseMode.loop);
      await _sfx.play(AssetSource(_soundAsset));
    } catch (e) {
      debugPrint('NotificationService._playForegroundChime error: $e');
    }
  }

  /// Hentikan nada dering foreground yang sedang berulang. Dipanggil UI saat
  /// pesanan dibuka atau banner ditutup.
  Future<void> stopAlertSound() async {
    try {
      await _sfx.stop();
    } catch (e) {
      debugPrint('NotificationService.stopAlertSound error: $e');
    }
  }

  Future<void> _showSystemNotification(String orderNumber, double total) async {
    if (!_initialized) await init();

    // Suara mengikuti preferensi lokal "Notifikasi Suara". Di Android suara
    // ditentukan oleh channel → pilih channel bersuara / senyap.
    final soundOn = AppSettings.soundNotifEnabled;
    final androidDetails = AndroidNotificationDetails(
      soundOn ? _channelSound : _channelSilent,
      soundOn ? _channelName : '$_channelName (senyap)',
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      playSound: soundOn,
      sound: soundOn
          ? const RawResourceAndroidNotificationSound(_soundResource)
          : null,
      enableVibration: true,
      ticker: 'Pesanan baru',
      category: AndroidNotificationCategory.message,
      // FLAG_INSISTENT (4): suara/getar notifikasi BERULANG sampai user
      // menyentuh atau menutup notifikasi (mis. saat app di background).
      additionalFlags: soundOn ? Int32List.fromList(<int>[4]) : null,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: soundOn,
      // File kustom hanya berbunyi bila ditambahkan ke bundle Runner (iOS);
      // bila tidak ada, iOS memakai suara default.
      sound: soundOn ? '$_soundResource.wav' : null,
    );

    final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
    await _plugin.show(
      id: id,
      title: 'Pesanan baru #$orderNumber',
      body: 'Pelanggan menunggu pembayaran',
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
    );
  }

  /// Stop watching + tutup stream listener (TIDAK menutup _eventController
  /// agar listener UI tetap valid kalau service di-restart).
  Future<void> stop() async {
    _stopping = true;
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    _pendingRecoveryTimer?.cancel();
    _pendingRecoveryTimer = null;
    _silenceBootstrap = true;
    await _realtimeSub?.cancel();
    _realtimeSub = null;
    final pendingTasks = _orderChangeTasks.toList();
    if (pendingTasks.isNotEmpty) {
      try {
        await Future.wait(pendingTasks);
      } catch (_) {
        // Cleanup auth/logout tetap lanjut setelah handler yang gagal selesai.
      }
    }
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    _pendingRecoveryTimer?.cancel();
    _pendingRecoveryTimer = null;
    _currentOutletId = null;
    if (_connectivityListenerAttached) {
      ConnectivityService.instance.online.removeListener(
        _recoverPendingWhenOnline,
      );
      _connectivityListenerAttached = false;
    }
    _nextBackgroundPollAt = null;
    _backgroundPollDelay = const Duration(seconds: 60);
    _lastPendingRecoveryAt = null;
    KeepAliveService.instance.onBackgroundTick = null;
    _recentlyNotified.clear();
    _kitchenPrintCompleted.clear();
    _ordersBeingProcessed.clear();
  }

  /// Tutup permanent (panggil hanya saat app shutdown).
  Future<void> dispose() async {
    if (_lifecycleObserverAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverAttached = false;
    }
    await stop();
    await _sfx.dispose();
    await _eventController.close();
  }
}

@visibleForTesting
DateTime notificationPollCutoff(DateTime now, DateTime lastRowsAt) =>
    NotificationService._pollCutoff(now, lastRowsAt);

@visibleForTesting
DateTime notificationEventCutoff(
  DateTime now,
  DateTime lastRowsAt, {
  required bool recoverAllPending,
}) => NotificationService._eventCutoff(
  now,
  lastRowsAt,
  recoverAllPending: recoverAllPending,
);

@visibleForTesting
Duration orderBackgroundPollDelay({
  required bool realtimeHealthy,
  required bool requestFailed,
  required Duration previous,
}) {
  if (!requestFailed) {
    return realtimeHealthy
        ? const Duration(minutes: 2)
        : const Duration(seconds: 30);
  }
  return Duration(seconds: (previous.inSeconds * 2).clamp(60, 300));
}

@visibleForTesting
bool pendingKitchenRecoveryIsDue(DateTime? lastAttempt, DateTime now) {
  if (lastAttempt == null || now.isBefore(lastAttempt)) return true;
  return now.difference(lastAttempt) >= const Duration(minutes: 2);
}

@visibleForTesting
bool kitchenPrintNeedsRecovery(KitchenPrintResult? result) {
  if (result == null) return true;
  if (result.hasPrinted || result.hasQueued) return false;
  return !const {
    'Belum ada printer Dapur yang aktif',
    'Cetak otomatis mati atau kategori belum sesuai dengan printer',
    'Semua kategori sengaja tidak dicetak',
    'Tiket dapur sudah pernah dicetak',
  }.contains(result.skippedReason);
}

/// Event yang dikirim ke listener UI saat order baru terdeteksi.
class NewOrderEvent {
  final String orderId;
  final String orderNumber;
  final String? tableId;
  final double totalAmount;
  final DateTime receivedAt;

  const NewOrderEvent({
    required this.orderId,
    required this.orderNumber,
    required this.tableId,
    required this.totalAmount,
    required this.receivedAt,
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/orders/data/datasources/orders_datasource.dart';
import '../../features/pos/data/datasources/pos_datasource.dart';
import '../../features/pos/data/datasources/shift_datasource.dart';
import '../models/enums.dart';
import 'backend_route_resolver.dart';
import 'connectivity_service.dart';
import 'error_log_service.dart';
import 'offline_queue_service.dart';
import 'supabase_service.dart';
import 'transaction_journal_service.dart';

/// Mengirim transaksi offline ke server begitu koneksi kembali.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  bool _running = false;
  bool _syncRequested = false;
  bool _started = false;
  bool _paused = false;
  Completer<void>? _idleCompleter;
  Timer? _retryTimer;
  int _retryStep = 0;
  StreamSubscription<AuthState>? _authSubscription;

  /// id order terbayar yang BARU SAJA sampai di server.
  ///
  /// Ada karena struk kini dicetak sebelum sinkron: saat kasir menekan Bayar,
  /// order belum ada di server, jadi pemeriksaan yang butuh order_id (mis. alert
  /// stok menipis) tak bisa lagi dijalankan di halaman bayar. Layar kasir
  /// menyimak notifier ini dan menjalankannya setelah order benar-benar masuk.
  final ValueNotifier<String?> lastPaidOrderSynced = ValueNotifier<String?>(
    null,
  );

  void start() {
    if (_started) return;
    _started = true;
    _paused = false;
    ConnectivityService.instance.online.addListener(_onConnectivityChange);
    ConnectivityService.instance.reachableRoute.addListener(
      _onReachableRouteChange,
    );
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      state,
    ) {
      if (state.event == AuthChangeEvent.signedIn ||
          state.event == AuthChangeEvent.tokenRefreshed ||
          state.event == AuthChangeEvent.initialSession) {
        if (ConnectivityService.instance.online.value) sync();
      }
    });
    // Coba sinkron langsung saat start jika sudah online.
    if (ConnectivityService.instance.online.value) {
      sync();
    }
  }

  void _onConnectivityChange() {
    if (ConnectivityService.instance.online.value) sync();
  }

  void _onReachableRouteChange() {
    if (ConnectivityService.instance.online.value &&
        ConnectivityService.instance.reachableRoute.value !=
            BackendRouteKind.unavailable) {
      sync();
    }
  }

  Future<void> dispose() async {
    await pause();
    ConnectivityService.instance.online.removeListener(_onConnectivityChange);
    ConnectivityService.instance.reachableRoute.removeListener(
      _onReachableRouteChange,
    );
    await _authSubscription?.cancel();
    _authSubscription = null;
    _syncRequested = false;
    _started = false;
  }

  /// Hentikan drain dan retry sebelum sesi staf ditukar atau dihapus.
  ///
  /// Operasi server yang sudah terlanjur berjalan ditunggu sampai selesai,
  /// sementara setiap loop berikutnya melihat [_paused] dan berhenti. Dengan
  /// begitu tidak ada RPC outbox/klaim cetak yang memakai sesi setelah logout.
  Future<void> pause() async {
    _paused = true;
    _syncRequested = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    final idle = _running ? (_idleCompleter ??= Completer<void>()) : null;
    if (idle != null) await idle.future;
  }

  /// Aktifkan kembali sinkronisasi setelah sesi staf siap.
  void resume() {
    _paused = false;
    if (_started && ConnectivityService.instance.online.value) {
      unawaited(sync());
    }
  }

  /// Retry bertahap untuk server/auth yang baru pulih. Timer hanya aktif pada
  /// runtime aplikasi (bukan unit test yang memanggil [sync] langsung).
  void _scheduleRetry() {
    if (_paused || !_started || _retryTimer?.isActive == true) return;
    const delays = [5, 15, 30, 60, 120];
    final seconds = delays[_retryStep.clamp(0, delays.length - 1)];
    if (_retryStep < delays.length - 1) _retryStep++;
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (ConnectivityService.instance.online.value) sync();
    });
  }

  void _resetRetry() {
    _retryStep = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<bool> _refreshExpiredSession() async {
    late final GoTrueClient auth;
    try {
      auth = Supabase.instance.client.auth;
    } catch (_) {
      return true;
    }
    final session = auth.currentSession;
    if (session == null || !session.isExpired) return true;
    try {
      await auth.refreshSession();
      return auth.currentSession != null;
    } catch (error) {
      debugPrint('SYNC: sesi login belum dapat dipulihkan → $error');
      _scheduleRetry();
      return false;
    }
  }

  /// Drain antrean satu per satu.
  ///
  /// Klasifikasi kegagalan:
  /// - [PostgrestException] → server MENOLAK (validasi/RLS/constraint). Retry
  ///   tidak akan menolong → pindahkan ke dead-letter dan LANJUT ke entri
  ///   berikutnya (cegah head-of-line blocking: satu order rusak tidak boleh
  ///   memblok order valid di belakangnya).
  /// - Error lain (jaringan/timeout) → kemungkinan offline lagi → berhenti,
  ///   dicoba ulang nanti saat koneksi kembali.
  Future<void> sync() async {
    if (_paused) return;
    if (_running) {
      // Antrean dapat bertambah saat snapshot drain sebelumnya masih berjalan.
      // Jangan abaikan pemicu tersebut: minta satu pass tambahan setelah pass
      // aktif selesai agar transaksi baru tidak menunggu perubahan koneksi.
      _syncRequested = true;
      return;
    }
    _running = true;
    try {
      do {
        _syncRequested = false;
        await _syncPass();
      } while (_syncRequested);
    } finally {
      _running = false;
      final idle = _idleCompleter;
      _idleCompleter = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  Future<void> _syncPass() async {
    if (_paused) return;
    if (!await _refreshExpiredSession()) return;
    if (_paused) return;
    await OfflineQueueService.instance.retryRecoverableDeadLetters();
    if (_paused) return;
    await _syncPendingShiftOpens();
    if (_paused) return;
    final ds = PosDatasource();
    for (final entry in OfflineQueueService.instance.all()) {
      if (_paused || !ConnectivityService.instance.online.value) break;
      try {
        final payload = _normalizeOfflineQueueTimestamps(entry.value);
        validateOfflineQueuePayload(payload);
        final shiftId = _optionalOfflineQueueString(payload, 'shiftId');
        if (shiftId != null && _hasUnresolvedShiftOpen(shiftId)) {
          // Foreign key shift harus tersedia sebelum header order dikirim.
          // Shift milik kasir lain atau yang ditolak server tetap menahan hanya
          // order dependennya, bukan seluruh transaksi outlet.
          continue;
        }
        String? currentUserId;
        try {
          currentUserId = Supabase.instance.client.auth.currentUser?.id;
        } catch (_) {
          // Unit test/startup sangat awal dapat mengantre sebelum Supabase
          // siap. Push di bawah tetap ditahan oleh catch jaringan/inisialisasi.
        }
        final createdBy = _requiredOfflineQueueString(payload, 'createdBy');
        if (createdBy != currentUserId) {
          final restored = await _tryRestoreStaffSession(createdBy);
          currentUserId = restored
              ? Supabase.instance.client.auth.currentUser?.id
              : currentUserId;
          if (createdBy != currentUserId) {
            // Jangan kirim transaksi kasir A memakai JWT akun device/kasir B.
            // Token yang dicabut membuat antrean menunggu clock-in online.
            continue;
          }
        }
        await ds.pushOfflineOrder(payload);
        await OfflineQueueService.instance.remove(entry.key);
        if (payload['kind'] == 'paid') {
          lastPaidOrderSynced.value = _optionalOfflineQueueString(
            payload,
            'clientOrderId',
          );
        }
      } on OfflineQueuePayloadException catch (e) {
        debugPrint('SYNC: payload order lokal rusak → dead-letter: $e');
        await OfflineQueueService.instance.moveToDeadLetter(
          entry.key,
          e.toString(),
          payloadOverride: entry.value,
        );
        // Kerusakan lokal tidak akan pulih karena retry. Lanjutkan order sah
        // berikutnya agar satu record korup tidak membekukan seluruh kasir.
      } on PostgrestException catch (e) {
        if (isRetryableSyncFailure(e)) {
          debugPrint(
            'SYNC: server/auth sementara belum siap → tetap antre: ${e.message}',
          );
          _scheduleRetry();
          break;
        }
        debugPrint('SYNC: order ditolak server → dead-letter: ${e.message}');
        unawaited(
          ErrorLogService.report(
            StateError(
              'Offline sync rejected '
              '[${entry.value['localReceiptNo'] ?? entry.value['clientOrderId']}]: '
              '${e.code ?? ''} ${e.message}',
            ),
            StackTrace.current,
          ),
        );
        await OfflineQueueService.instance.moveToDeadLetter(
          entry.key,
          'PostgrestException ${e.code ?? ''}: ${e.message}',
          payloadOverride: entry.value,
        );
        // JANGAN break — teruskan drain antrean.
      } catch (e) {
        debugPrint('SYNC: gagal (jaringan?) → stop, retry nanti → $e');
        _scheduleRetry();
        break;
      }
    }
    await _syncJournal();
    if (OfflineQueueService.instance.pendingCount.value == 0 &&
        TransactionJournalService.instance.pendingCount.value == 0) {
      _resetRetry();
    }
  }

  /// Replay mutations which are not represented by the legacy paid-order
  /// queue (payments on existing orders and partial payments). Every payload
  /// carries a durable idempotency key; a timeout is therefore safe to retry.
  Future<void> _syncJournal() async {
    final journal = TransactionJournalService.instance;
    final entries =
        journal
            .all(includeAttention: false)
            .where(
              (e) =>
                  e['type'] != 'shift_open' &&
                  (e['status'] == 'pending' || e['status'] == 'sending'),
            )
            .toList()
          ..sort((a, b) {
            // Penutupan shift selalu paling akhir, walaupun timestamp
            // perangkat meleset. Semua pembayaran/append harus lebih dulu.
            final priority = _journalPriority(
              a['type'],
            ).compareTo(_journalPriority(b['type']));
            if (priority != 0) return priority;
            return _journalString(
              a['createdAt'],
            ).compareTo(_journalString(b['createdAt']));
          });
    if (entries.isEmpty) return;

    late final SupabaseClient client;
    try {
      client = Supabase.instance.client;
    } catch (_) {
      // Unit tests and very early startup can invoke the legacy queue before
      // Supabase has been initialized. Leave the journal untouched for the
      // normal startup pass.
      return;
    }
    var currentUserId = client.auth.currentUser?.id;
    final ds = OrdersDatasource();
    for (final entry in entries) {
      if (_paused) break;
      final id = entry['id'] as String;
      try {
        final payload = (entry['payload'] as Map?)?.cast<String, dynamic>();
        if (payload == null) {
          throw const _JournalPayloadException(
            'Payload jurnal transaksi tidak valid',
          );
        }
        _validateJournalPayload(entry['type'], payload);

        final parentOrderId = _optionalJournalString(payload, 'orderId');
        if (parentOrderId != null &&
            OfflineQueueService.instance.findByClientOrderId(parentOrderId) !=
                null) {
          // Append/edit/payment dapat dibuat sesudah order lokal "Ke Dapur".
          // Header order wajib tersinkron lebih dulu; bila push order berhenti
          // karena jaringan, jangan kirim mutasi anak lalu salah dianggap
          // penolakan permanen akibat order_id belum ada di server.
          continue;
        }

        if (entry['type'] == 'shift_close') {
          final closingShiftId = _requiredJournalString(payload, 'shiftId');
          if (_hasUnresolvedShiftDependencies(closingShiftId, id)) {
            // Penutupan harus menjadi operasi TERAKHIR shift. Jika order atau
            // pembayaran masih tertahan, server belum boleh mengunci shift.
            continue;
          }
        }

        final expectedUserId = _optionalJournalString(
          payload,
          'expectedUserId',
        );
        // Do not replay a payment using the device account or another staff
        // account after a restart. It remains pending until the right staff
        // clocks in again.
        if (expectedUserId != null && expectedUserId != currentUserId) {
          final restored = await _tryRestoreStaffSession(expectedUserId);
          currentUserId = restored
              ? client.auth.currentUser?.id
              : currentUserId;
          if (expectedUserId != currentUserId) continue;
        }

        // Jurnal baru menyimpan waktu kasir menekan bayar. Untuk jurnal versi
        // lama, waktu enqueue adalah fallback paling dekat dan jauh lebih benar
        // daripada DateTime server ketika koneksi akhirnya pulih.
        final rawPaidAt =
            _optionalJournalString(payload, 'paidAt') ??
            _optionalJournalString(entry, 'createdAt');
        final paidAt = rawPaidAt == null
            ? null
            : ConnectivityService.instance.normalizeQueuedTimestamp(
                rawPaidAt,
                source:
                    _optionalJournalString(payload, 'paidAtClockSource') ??
                    // Jurnal sebelum metadata clock diperkenalkan dibuat
                    // langsung dari DateTime perangkat.
                    'device',
              );

        await journal.markSending(id);
        switch (entry['type']) {
          case 'existing_payment':
            await ds.processPayment(
              orderId: payload['orderId'] as String,
              outletId: payload['outletId'] as String,
              method: PaymentMethodX.fromString(payload['method'] as String),
              amount: (payload['amount'] as num).toDouble(),
              tillShiftId: payload['shiftId'] as String?,
              expectedUserId: expectedUserId,
              idempotencyKey: payload['idempotencyKey'] as String,
              paidAt: paidAt,
            );
            break;
          case 'split_payment':
            await ds.addSplitPayment(
              orderId: payload['orderId'] as String,
              outletId: payload['outletId'] as String,
              shiftId: payload['shiftId'] as String,
              method: PaymentMethodX.fromString(payload['method'] as String),
              amount: (payload['amount'] as num).toDouble(),
              finalize: payload['finalize'] == true,
              idempotencyKey: payload['idempotencyKey'] as String,
              paidAt: paidAt,
            );
            break;
          case 'split_finalize':
            await ds.finalizeSplitPayment(payload['orderId'] as String);
            break;
          case 'append_order_items':
            await client.rpc(
              'append_order_items',
              params: {
                'p_order_id': payload['orderId'],
                'p_items': payload['items'],
                'p_tax_percent': payload['taxPercent'],
                'p_tax_active': payload['taxActive'],
                'p_service_charge_percent': payload['serviceChargePercent'],
                'p_request_id': payload['requestId'],
              },
            );
            break;
          case 'replace_online_order_items':
            await client.rpc(
              'replace_online_order_items',
              params: {
                'p_order_id': payload['orderId'],
                'p_items': payload['items'],
                'p_customer_name': payload['customerName'],
              },
            );
            break;
          case 'cash_movement':
            final rawCreatedAt = _requiredJournalString(payload, 'createdAt');
            final createdAt = ConnectivityService.instance
                .normalizeQueuedTimestamp(
                  rawCreatedAt,
                  source:
                      _optionalJournalString(payload, 'clockSource') ??
                      'device',
                );
            await ShiftDatasource().replayCashMovement(
              requestId: _requiredJournalString(payload, 'requestId'),
              shiftId: _requiredJournalString(payload, 'shiftId'),
              outletId: _requiredJournalString(payload, 'outletId'),
              type: _requiredJournalString(payload, 'type'),
              amount: (payload['amount'] as num).toDouble(),
              note: _optionalJournalString(payload, 'note'),
              expenseCategory:
                  _optionalJournalString(payload, 'expenseCategory') ??
                  'operasional',
              createdAt: DateTime.parse(createdAt),
            );
            break;
          case 'shift_close':
            final rawClosedAt = _requiredJournalString(payload, 'closedAt');
            final closedAt = ConnectivityService.instance
                .normalizeQueuedTimestamp(
                  rawClosedAt,
                  source:
                      _optionalJournalString(payload, 'clockSource') ??
                      'device',
                );
            await ShiftDatasource().replayOfflineShiftClose(
              shiftId: _requiredJournalString(payload, 'shiftId'),
              closingCash: (payload['closingCash'] as num).toDouble(),
              notes: _optionalJournalString(payload, 'notes'),
              closedAt: DateTime.parse(closedAt),
            );
            await PosDatasource().forgetOpenShift(
              outletId: _requiredJournalString(payload, 'outletId'),
              shiftId: _requiredJournalString(payload, 'shiftId'),
              kasirId: expectedUserId,
            );
            break;
          default:
            await journal.markNeedsReview(
              id,
              StateError('Jenis transaksi belum didukung: ${entry['type']}'),
            );
            continue;
        }
        await journal.remove(id);
      } catch (error) {
        if (isRetryableSyncFailure(error)) {
          await journal.markPending(id, error);
          _scheduleRetry();
          // Preserve ordering: later operations can depend on this one.
          break;
        }
        await journal.markNeedsReview(id, error);
      }
    }
  }

  /// Shift lokal adalah prasyarat foreign-key bagi order dan payment. Replay
  /// lebih dulu, tetapi hanya untuk akun pembuat yang sedang aktif; transaksi
  /// kasir lain tetap menunggu tanpa memblok kasir saat ini.
  Future<void> _syncPendingShiftOpens() async {
    final journal = TransactionJournalService.instance;
    final entries =
        journal
            .all(includeAttention: false)
            .where(
              (entry) =>
                  entry['type'] == 'shift_open' &&
                  (entry['status'] == 'pending' ||
                      entry['status'] == 'sending'),
            )
            .toList()
          ..sort(
            (a, b) => _journalString(
              a['createdAt'],
            ).compareTo(_journalString(b['createdAt'])),
          );
    if (entries.isEmpty) return;

    late final SupabaseClient client;
    try {
      client = Supabase.instance.client;
    } catch (_) {
      return;
    }
    var currentUserId = client.auth.currentUser?.id;
    final shifts = ShiftDatasource();
    for (final entry in entries) {
      if (_paused) break;
      final id = entry['id'] as String;
      try {
        final payload = (entry['payload'] as Map?)?.cast<String, dynamic>();
        if (payload == null) {
          throw const _JournalPayloadException(
            'Payload pembukaan shift tidak valid',
          );
        }
        _validateJournalPayload('shift_open', payload);
        final expectedUserId = _requiredJournalString(
          payload,
          'expectedUserId',
        );
        if (expectedUserId != currentUserId) {
          final restored = await _tryRestoreStaffSession(expectedUserId);
          currentUserId = restored
              ? client.auth.currentUser?.id
              : currentUserId;
          if (expectedUserId != currentUserId) continue;
        }

        final rawStartedAt = _requiredJournalString(payload, 'startedAt');
        final startedAt = ConnectivityService.instance.normalizeQueuedTimestamp(
          rawStartedAt,
          source: _optionalJournalString(payload, 'clockSource') ?? 'device',
        );
        await journal.markSending(id);
        await shifts.replayOfflineShiftOpen(
          shiftId: _requiredJournalString(payload, 'shiftId'),
          outletId: _requiredJournalString(payload, 'outletId'),
          kasirId: _requiredJournalString(payload, 'kasirId'),
          openingCash: (payload['openingCash'] as num).toDouble(),
          startedAt: DateTime.parse(startedAt),
        );
        await journal.remove(id);
      } catch (error) {
        if (isRetryableSyncFailure(error)) {
          await journal.markPending(id, error);
          _scheduleRetry();
          // Shift berikutnya milik kasir yang sama dapat berbenturan sampai
          // prasyarat ini pulih; coba lagi pada pass berikutnya.
          break;
        }
        await journal.markNeedsReview(id, error);
      }
    }
  }

  bool _hasUnresolvedShiftOpen(String shiftId) {
    return TransactionJournalService.instance.all().any((entry) {
      if (entry['type'] != 'shift_open') return false;
      final status = entry['status'];
      if (status != 'pending' && status != 'sending') return false;
      final payload = entry['payload'];
      return payload is Map && payload['shiftId'] == shiftId;
    });
  }

  bool _hasUnresolvedShiftDependencies(String shiftId, String closingEntryId) {
    final queuedOrder = OfflineQueueService.instance.all().any(
      (entry) => entry.value['shiftId'] == shiftId,
    );
    if (queuedOrder) return true;
    return TransactionJournalService.instance.all().any((entry) {
      if (entry['id'] == closingEntryId) {
        return false;
      }
      final payload = entry['payload'];
      return payload is Map && payload['shiftId'] == shiftId;
    });
  }

  /// Supabase dapat belum terinisialisasi pada frame startup pertama atau
  /// pada unit test cache-only. Pemulihan sesi adalah optimasi sinkronisasi,
  /// bukan alasan untuk membuang antrean maupun melempar error latar.
  Future<bool> _tryRestoreStaffSession(String staffId) async {
    try {
      return await SupabaseService().restoreStaffSessionForSync(staffId);
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _normalizeOfflineQueueTimestamps(
    Map<String, dynamic> original,
  ) {
    final payload = Map<String, dynamic>.from(original);
    final createdAt = _optionalOfflineQueueString(payload, 'createdAt');
    if (createdAt == null) return payload;
    payload['createdAt'] = ConnectivityService.instance
        .normalizeQueuedTimestamp(
          createdAt,
          source:
              // Payload lama belum membawa clockSource dan menggunakan jam
              // perangkat, sehingga perlu dikoreksi setelah server terjangkau.
              _optionalOfflineQueueString(payload, 'clockSource') ?? 'device',
        );
    final paidAt = _optionalOfflineQueueString(payload, 'paidAt');
    if (paidAt != null) {
      payload['paidAt'] = ConnectivityService.instance.normalizeQueuedTimestamp(
        paidAt,
        source:
            _optionalOfflineQueueString(payload, 'paidAtClockSource') ??
            _optionalOfflineQueueString(payload, 'clockSource') ??
            'device',
      );
    }
    final rawPayments = payload['payments'];
    if (rawPayments is List) {
      payload['payments'] = [
        for (final rawPayment in rawPayments)
          if (rawPayment is Map)
            () {
              final payment = Map<String, dynamic>.from(rawPayment);
              final splitPaidAt = _optionalOfflineQueueString(
                payment,
                'paidAt',
              );
              if (splitPaidAt != null) {
                payment['paidAt'] = ConnectivityService.instance
                    .normalizeQueuedTimestamp(
                      splitPaidAt,
                      source:
                          _optionalOfflineQueueString(
                            payment,
                            'paidAtClockSource',
                          ) ??
                          _optionalOfflineQueueString(payload, 'clockSource') ??
                          'device',
                    );
              }
              return payment;
            }()
          else
            rawPayment,
      ];
    }
    return payload;
  }
}

String _journalString(Object? value) => value is String ? value : '';

int _journalPriority(Object? type) => type == 'shift_close' ? 1 : 0;

String? _optionalJournalString(Map<dynamic, dynamic> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is String && value.trim().isNotEmpty) return value;
  throw _JournalPayloadException('Field jurnal $key tidak valid');
}

String _requiredJournalString(Map<dynamic, dynamic> source, String key) {
  final value = _optionalJournalString(source, key);
  if (value == null) {
    throw _JournalPayloadException('Field jurnal $key wajib diisi');
  }
  return value;
}

void _validateJournalPayload(Object? type, Map<String, dynamic> payload) {
  _optionalJournalString(payload, 'expectedUserId');
  final paidAt = _optionalJournalString(payload, 'paidAt');
  if (paidAt != null && DateTime.tryParse(paidAt) == null) {
    throw const _JournalPayloadException('Waktu pembayaran jurnal tidak valid');
  }

  switch (type) {
    case 'shift_open':
      _requiredJournalString(payload, 'shiftId');
      _requiredJournalString(payload, 'outletId');
      _requiredJournalString(payload, 'kasirId');
      _requiredJournalString(payload, 'expectedUserId');
      final startedAt = _requiredJournalString(payload, 'startedAt');
      if (DateTime.tryParse(startedAt) == null) {
        throw const _JournalPayloadException(
          'Waktu pembukaan shift tidak valid',
        );
      }
      final openingCash = payload['openingCash'];
      if (openingCash is! num || !openingCash.isFinite || openingCash < 0) {
        throw const _JournalPayloadException('Modal awal shift tidak valid');
      }
      return;
    case 'shift_close':
      _requiredJournalString(payload, 'shiftId');
      _requiredJournalString(payload, 'outletId');
      _requiredJournalString(payload, 'expectedUserId');
      final closedAt = _requiredJournalString(payload, 'closedAt');
      if (DateTime.tryParse(closedAt) == null) {
        throw const _JournalPayloadException(
          'Waktu penutupan shift tidak valid',
        );
      }
      final closingCash = payload['closingCash'];
      if (closingCash is! num || !closingCash.isFinite || closingCash < 0) {
        throw const _JournalPayloadException(
          'Uang penutupan shift tidak valid',
        );
      }
      _optionalJournalString(payload, 'notes');
      return;
    case 'cash_movement':
      _requiredJournalString(payload, 'requestId');
      _requiredJournalString(payload, 'shiftId');
      _requiredJournalString(payload, 'outletId');
      _requiredJournalString(payload, 'expectedUserId');
      final movementType = _requiredJournalString(payload, 'type');
      if (movementType != 'in' && movementType != 'out') {
        throw const _JournalPayloadException(
          'Jenis pergerakan kas tidak valid',
        );
      }
      final amount = payload['amount'];
      if (amount is! num || !amount.isFinite || amount <= 0) {
        throw const _JournalPayloadException(
          'Nominal pergerakan kas tidak valid',
        );
      }
      final createdAt = _requiredJournalString(payload, 'createdAt');
      if (DateTime.tryParse(createdAt) == null) {
        throw const _JournalPayloadException(
          'Waktu pergerakan kas tidak valid',
        );
      }
      _optionalJournalString(payload, 'note');
      _optionalJournalString(payload, 'expenseCategory');
      return;
    case 'existing_payment':
      _requiredJournalString(payload, 'orderId');
      _requiredJournalString(payload, 'outletId');
      _optionalJournalString(payload, 'shiftId');
      _validateJournalPayment(payload);
      return;
    case 'split_payment':
      _requiredJournalString(payload, 'orderId');
      _requiredJournalString(payload, 'outletId');
      _requiredJournalString(payload, 'shiftId');
      _validateJournalPayment(payload);
      return;
    case 'split_finalize':
      _requiredJournalString(payload, 'orderId');
      return;
    case 'append_order_items':
      _requiredJournalString(payload, 'orderId');
      _requiredJournalString(payload, 'outletId');
      _requiredJournalString(payload, 'requestId');
      final items = payload['items'];
      if (items is! List || items.isEmpty) {
        throw const _JournalPayloadException(
          'Item tambahan jurnal tidak valid',
        );
      }
      if (payload['taxPercent'] is! num ||
          payload['taxActive'] is! bool ||
          payload['serviceChargePercent'] is! num) {
        throw const _JournalPayloadException(
          'Komponen biaya item tambahan tidak valid',
        );
      }
      return;
    case 'replace_online_order_items':
      _requiredJournalString(payload, 'orderId');
      _requiredJournalString(payload, 'outletId');
      _optionalJournalString(payload, 'customerName');
      final items = payload['items'];
      if (items is! List ||
          items.isEmpty ||
          items.any((item) => item is! Map)) {
        throw const _JournalPayloadException(
          'Item pengganti pesanan online tidak valid',
        );
      }
      return;
    default:
      throw _JournalPayloadException(
        'Jenis transaksi belum didukung: ${type ?? 'null'}',
      );
  }
}

void _validateJournalPayment(Map<String, dynamic> payload) {
  final method = _requiredJournalString(payload, 'method');
  if (!PaymentMethod.values.any((value) => value.value == method)) {
    throw const _JournalPayloadException(
      'Metode pembayaran jurnal tidak valid',
    );
  }
  _requiredJournalString(payload, 'idempotencyKey');
  final amount = payload['amount'];
  if (amount is! num || !amount.isFinite || amount <= 0) {
    throw const _JournalPayloadException(
      'Nominal pembayaran jurnal tidak valid',
    );
  }
}

String? _optionalOfflineQueueString(Map<String, dynamic> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is String && value.trim().isNotEmpty) return value;
  throw OfflineQueuePayloadException('Field antrean $key tidak valid');
}

String _requiredOfflineQueueString(Map<String, dynamic> source, String key) {
  final value = _optionalOfflineQueueString(source, key);
  if (value == null) {
    throw OfflineQueuePayloadException('Field antrean $key wajib diisi');
  }
  return value;
}

/// Kesalahan data lokal yang tidak mungkin pulih hanya dengan mencoba ulang.
/// Dibedakan dari [FormatException] karena respons HTTP/gateway yang rusak
/// memang dapat menghasilkan FormatException dan tetap layak di-retry.
class _JournalPayloadException implements Exception {
  const _JournalPayloadException(this.message);

  final String message;

  @override
  String toString() => 'JournalPayloadException: $message';
}

/// Error yang tidak membuktikan payload transaksi salah. Entri wajib tetap di
/// antrean karena token dapat diperbarui dan gangguan PostgREST 5xx dapat pulih.
@visibleForTesting
bool isRetryableSyncFailure(Object error) {
  if (isBackendTransportFailure(error) || error is AuthException) return true;
  if (error is! PostgrestException) return false;

  final code = (error.code ?? '').toUpperCase();
  if (const {
    'PGRST000',
    'PGRST001',
    'PGRST002',
    'PGRST301',
    'PGRST302',
  }.contains(code)) {
    return true;
  }
  final text = [
    error.message,
    error.details?.toString() ?? '',
    error.hint ?? '',
  ].join(' ').toLowerCase();
  return text.contains('jwt expired') ||
      text.contains('invalid jwt') ||
      text.contains('token has expired') ||
      text.contains('not authenticated') ||
      text.contains('created_by harus merupakan pengguna yang sedang login');
}

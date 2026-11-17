import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

const _retryableJournalTypes = <String>{
  'existing_payment',
  'split_payment',
  'split_finalize',
  'append_order_items',
  'cash_movement',
  'shift_open',
  'shift_close',
};

/// Diagnosis satu mutasi yang belum mendapat konfirmasi final dari server.
/// Tidak memuat PIN karena PIN memang tidak pernah ditulis ke jurnal lokal.
class TransactionJournalDiagnostic {
  final String storageKey;
  final String id;
  final String type;
  final String status;
  final int attempts;
  final String createdAt;
  final String updatedAt;
  final String lastError;
  final Map<String, dynamic> payload;
  final bool isCorrupt;

  const TransactionJournalDiagnostic({
    required this.storageKey,
    required this.id,
    required this.type,
    required this.status,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    required this.lastError,
    required this.payload,
    this.isCorrupt = false,
  });

  String? get orderId => _journalText(payload['orderId']);
  String? get outletId => _journalText(payload['outletId']);
  String? get shiftId => _journalText(payload['shiftId']);
  String? get expectedUserId => _journalText(payload['expectedUserId']);
  String? get operation => _journalText(payload['operation']);

  bool get retryable =>
      !isCorrupt &&
      status == 'needs_review' &&
      _retryableJournalTypes.contains(type);

  String get title {
    if (isCorrupt) return 'Data jurnal rusak';
    switch (type) {
      case 'existing_payment':
        return 'Pembayaran order';
      case 'split_payment':
        return 'Bagian split payment';
      case 'split_finalize':
        return 'Finalisasi split payment';
      case 'append_order_items':
        return 'Tambah item order';
      case 'cash_movement':
        return 'Kas masuk/keluar offline';
      case 'shift_open':
        return 'Pembukaan kasir offline';
      case 'shift_close':
        return 'Penutupan kasir offline';
      case 'manual_review':
        switch (operation) {
          case 'void_order':
            return 'Void order perlu verifikasi';
          case 'void_order_items':
            return 'Void item perlu verifikasi';
          case 'refund_order':
            return 'Refund order perlu verifikasi';
          case 'refund_order_items':
            return 'Refund item perlu verifikasi';
          case 'cash_movement':
            return 'Pergerakan kas perlu diperiksa';
          case 'close_shift':
            return 'Penutupan kasir perlu diperiksa';
          default:
            return 'Operasi perlu pemeriksaan';
        }
      default:
        return 'Transaksi ${type.isEmpty ? 'tidak dikenal' : type}';
    }
  }

  String get reference => orderId ?? shiftId ?? id;

  String get amountSummary {
    final method = _journalText(payload['method']);
    final amount = payload['amount'] ?? payload['total'];
    if (method != null && amount != null) return '$method · $amount';
    if (amount != null) return amount.toString();
    return '-';
  }

  String get readableReason {
    if (isCorrupt) {
      return 'Isi jurnal lokal tidak dapat dibaca. Data dipertahankan dan '
          'perlu diperiksa sebelum dibersihkan.';
    }
    final lower = lastError.toLowerCase();
    if (lower.contains('menunggu verifikasi pin')) {
      return 'Operasi disimpan tanpa PIN. Buka order saat online dan lakukan '
          'otorisasi kembali; PIN tidak disimpan di perangkat.';
    }
    if (lower.contains('till sudah ditutup') ||
        lower.contains('shift pembayaran sudah ditutup')) {
      return 'Till pada payload sudah ditutup. Periksa ID till dan waktu '
          'transaksi sebelum mencoba ulang.';
    }
    if (lower.contains('belum melunasi') ||
        lower.contains('nominal') ||
        lower.contains('total resmi')) {
      return 'Nominal perangkat berbeda dengan perhitungan server. Periksa '
          'rincian pembayaran, pajak, layanan, promo, dan refund.';
    }
    if (lower.contains('sudah lunas') || lower.contains('already paid')) {
      return 'Server menyatakan order sudah lunas. Periksa riwayat pembayaran '
          'sebelum mengirim ulang agar tidak tercatat dua kali.';
    }
    if (lower.contains('jwt') ||
        lower.contains('not authenticated') ||
        lower.contains('created_by') ||
        lower.contains('pengguna yang sedang login')) {
      return 'Sesi pengguna tidak sesuai. Login sebagai pengguna pembuat '
          'transaksi lalu coba sinkronkan kembali.';
    }
    if (type == 'manual_review') {
      return 'Respons akhir server belum dapat dipastikan. Periksa operasi ini '
          'dari layar asal sebelum mengulangnya.';
    }
    return 'Server menolak operasi. Periksa detail dan status order sebelum '
        'mencoba ulang transaksi ini.';
  }

  String get guidance {
    if (isCorrupt) return 'Salin detail untuk pemeriksaan teknis.';
    if (type == 'manual_review') {
      if (operation == 'cash_movement' || operation == 'close_shift') {
        return 'Periksa laporan kas/shift di server sebelum mengulangi aksi.';
      }
      return 'Buka detail order saat online, lalu ulangi dengan persetujuan dan PIN.';
    }
    return retryable
        ? 'Aman dicoba ulang karena operasi memiliki identitas yang tetap.'
        : 'Periksa status server sebelum melakukan tindakan.';
  }

  String get clipboardText {
    final lines = <String>[
      'Diagnostik jurnal transaksi',
      'Jenis: $title',
      'ID jurnal: $id',
      'Referensi: $reference',
      'Status: $status',
      'Percobaan: $attempts',
      'ID order: ${orderId ?? '-'}',
      'ID outlet: ${outletId ?? '-'}',
      'ID till: ${shiftId ?? '-'}',
      'ID pengguna: ${expectedUserId ?? '-'}',
      if (_journalText(payload['paidAt']) != null)
        'Waktu bayar: ${_journalText(payload['paidAt'])}',
      if (operation != null) 'Operasi: $operation',
      'Pembayaran/nominal: $amountSummary',
      'Dibuat: ${createdAt.isEmpty ? '-' : createdAt}',
      'Diperbarui: ${updatedAt.isEmpty ? '-' : updatedAt}',
      'Penjelasan: $readableReason',
      'Tindakan: $guidance',
      'Pesan terakhir: ${lastError.isEmpty ? '-' : lastError}',
    ];
    return lines.join('\n');
  }
}

String? _journalText(dynamic value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

/// Durable outbox for server mutations whose response can be lost on an
/// unstable connection. An entry is removed only after the server confirms
/// the mutation; validation errors stay visible for manual review.
class TransactionJournalService {
  TransactionJournalService._();
  static final TransactionJournalService instance =
      TransactionJournalService._();

  static const boxName = 'transaction_journal_secure_v1';
  static const legacyBoxName = 'transaction_journal';

  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);
  final ValueNotifier<int> attentionCount = ValueNotifier<int>(0);

  Box get _box => Hive.box(boxName);

  void init() {
    if (Hive.isBoxOpen(boxName)) {
      // A process killed while a request was in-flight must be retried only
      // after the server idempotency check, never treated as successful.
      for (final key in _box.keys.toList()) {
        final entry = _decode(_box.get(key));
        if (entry?['status'] == 'sending') {
          entry!['status'] = 'pending';
          entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
          _box.put(key, jsonEncode(entry));
        }
      }
      _refresh();
    }
  }

  Future<void> enqueue({
    required String id,
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _box.put(
      id,
      jsonEncode({
        'id': id,
        'type': type,
        'payload': payload,
        'status': 'pending',
        'attempts': 0,
        'createdAt': now,
        'updatedAt': now,
        'lastError': null,
      }),
    );
    _refresh();
  }

  List<Map<String, dynamic>> all({bool includeAttention = true}) {
    if (!Hive.isBoxOpen(boxName)) return const [];
    return _box.values
        .map(_decode)
        .whereType<Map<String, dynamic>>()
        .where(_isValidEntry)
        .where(
          (entry) =>
              includeAttention ||
              (entry['status'] as String?) != 'needs_review',
        )
        .toList();
  }

  Map<String, dynamic>? get(String id) {
    final entry = _decode(_box.get(id));
    return entry != null && _isValidEntry(entry) ? entry : null;
  }

  /// Seluruh entri untuk UI diagnostik, termasuk data lokal yang rusak dan
  /// dahulu tidak terlihat karena gagal di-decode.
  List<TransactionJournalDiagnostic> diagnostics({bool attentionOnly = false}) {
    if (!Hive.isBoxOpen(boxName)) return const [];
    final result = <TransactionJournalDiagnostic>[];
    for (final rawEntry in _box.toMap().entries) {
      final entry = _decode(rawEntry.value);
      final valid = entry != null && _isValidEntry(entry);
      if (!valid) {
        result.add(
          TransactionJournalDiagnostic(
            storageKey: rawEntry.key.toString(),
            id: rawEntry.key.toString(),
            type: 'corrupt',
            status: 'needs_review',
            attempts: 0,
            createdAt: '',
            updatedAt: '',
            lastError: 'Payload jurnal lokal tidak valid atau terpotong',
            payload: const {},
            isCorrupt: true,
          ),
        );
        continue;
      }
      if (attentionOnly && entry['status'] != 'needs_review') continue;
      result.add(
        TransactionJournalDiagnostic(
          storageKey: rawEntry.key.toString(),
          id: entry['id'] as String,
          type: entry['type'] as String,
          status: entry['status'] as String,
          attempts: (entry['attempts'] as num?)?.toInt() ?? 0,
          createdAt: entry['createdAt'] as String? ?? '',
          updatedAt: entry['updatedAt'] as String? ?? '',
          lastError: entry['lastError']?.toString() ?? '',
          payload: (entry['payload'] as Map).cast<String, dynamic>(),
        ),
      );
    }
    return result;
  }

  Future<void> markSending(String id) async {
    final entry = get(id);
    if (entry == null) return;
    entry['status'] = 'sending';
    entry['attempts'] = ((entry['attempts'] as num?)?.toInt() ?? 0) + 1;
    entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _box.put(id, jsonEncode(entry));
    _refresh();
  }

  Future<void> markPending(String id, [Object? error]) async {
    final entry = get(id);
    if (entry == null) return;
    entry['status'] = 'pending';
    entry['lastError'] = error?.toString();
    entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _box.put(id, jsonEncode(entry));
    _refresh();
  }

  Future<void> markNeedsReview(String id, Object error) async {
    final entry = get(id);
    if (entry == null) return;
    entry['status'] = 'needs_review';
    entry['lastError'] = error.toString();
    entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _box.put(id, jsonEncode(entry));
    _refresh();
  }

  Future<void> remove(String id) async {
    await _box.delete(id);
    _refresh();
  }

  /// Hapus permintaan sensitif offline setelah aksi yang sama telah
  /// diverifikasi PIN dan berhasil di server. [items] membatasi resolusi pada
  /// pilihan item yang sama agar permintaan parsial lain tidak ikut hilang.
  Future<int> resolveManualReviews({
    required String operation,
    required String orderId,
    List<Map<String, dynamic>>? items,
  }) async {
    try {
      final expectedItems = items == null ? null : _itemSignature(items);
      final resolvedKeys = <dynamic>[];
      for (final key in _box.keys.toList()) {
        final entry = _decode(_box.get(key));
        if (entry?['type'] != 'manual_review' ||
            entry?['status'] != 'needs_review') {
          continue;
        }
        final payload = entry?['payload'];
        if (payload is! Map ||
            payload['operation'] != operation ||
            payload['orderId'] != orderId) {
          continue;
        }
        if (expectedItems != null &&
            _itemSignature(payload['items']) != expectedItems) {
          continue;
        }
        resolvedKeys.add(key);
      }
      if (resolvedKeys.isNotEmpty) await _box.deleteAll(resolvedKeys);
      _refresh();
      return resolvedKeys.length;
    } catch (error) {
      // Aksi server sudah sah; kegagalan housekeeping lokal tidak boleh
      // mengubahnya menjadi pesan void/refund gagal atau memicu pengulangan.
      debugPrint('JOURNAL: gagal membersihkan manual review → $error');
      return 0;
    }
  }

  Future<void> retryAllAttention() async {
    for (final entry in all()) {
      if (entry['status'] == 'needs_review' &&
          _retryableJournalTypes.contains(entry['type'])) {
        entry['status'] = 'pending';
        entry['lastError'] = null;
        entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
        await _box.put(entry['id'], jsonEncode(entry));
      }
    }
    _refresh();
  }

  /// Coba ulang satu mutasi idempoten. Void/refund tetap perlu pemeriksaan dan
  /// PIN; kas serta tutup shift versi baru aman karena membawa request ID tetap.
  Future<bool> retryAttention(String id) async {
    final entry = get(id);
    if (entry == null ||
        entry['status'] != 'needs_review' ||
        !_retryableJournalTypes.contains(entry['type'])) {
      return false;
    }
    entry['status'] = 'pending';
    entry['lastError'] = null;
    entry['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _box.put(id, jsonEncode(entry));
    _refresh();
    return true;
  }

  void _refresh() {
    final entries = diagnostics();
    pendingCount.value = entries
        .where((e) => e.status == 'pending' || e.status == 'sending')
        .length;
    attentionCount.value = entries
        .where((e) => e.status == 'needs_review')
        .length;
  }

  Map<String, dynamic>? _decode(Object? raw) {
    if (raw is! String) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  bool _isValidEntry(Map<String, dynamic> entry) {
    final id = entry['id'];
    final type = entry['type'];
    final status = entry['status'];
    return id is String &&
        id.isNotEmpty &&
        type is String &&
        type.isNotEmpty &&
        status is String &&
        const {'pending', 'sending', 'needs_review'}.contains(status) &&
        entry['payload'] is Map;
  }

  String _itemSignature(Object? raw) {
    if (raw is! List) return '';
    final normalized =
        raw.whereType<Map>().map((item) {
          return <String, dynamic>{
            'order_item_id': item['order_item_id']?.toString(),
            'qty': (item['qty'] as num?)?.toInt(),
          };
        }).toList()..sort(
          (a, b) => (a['order_item_id'] as String? ?? '').compareTo(
            b['order_item_id'] as String? ?? '',
          ),
        );
    return jsonEncode(normalized);
  }
}

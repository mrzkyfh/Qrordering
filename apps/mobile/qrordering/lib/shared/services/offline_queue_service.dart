import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/enums.dart';

/// Satu transaksi yang ditolak server beserta konteks yang diperlukan untuk
/// menelusuri dan memulihkannya. Data ini hanya berasal dari penyimpanan lokal
/// perangkat; tidak ada payload finansial yang dihapus otomatis.
class DeadLetterDiagnostic {
  final dynamic key;
  final String error;
  final String failedAt;
  final Map<String, dynamic> payload;

  const DeadLetterDiagnostic({
    required this.key,
    required this.error,
    required this.failedAt,
    required this.payload,
  });

  String get localReference =>
      _text(payload['localReceiptNo']) ??
      _text(payload['clientOrderId']) ??
      'Tanpa nomor lokal';

  String? get shiftId => _text(payload['shiftId']);
  String? get originalShiftId => _text(payload['originalShiftId']);
  String? get createdAt => _text(payload['createdAt']);
  String? get createdBy => _text(payload['createdBy']);
  String? get shiftStartedAt => _text(payload['shiftStartedAt']);
  String? get shiftVerifiedAt => _text(payload['shiftVerifiedAt']);
  String? get shiftSource => _text(payload['shiftSource']);

  String get paymentSummary {
    final split = (payload['payments'] as List?)
        ?.whereType<Map>()
        .map((entry) {
          final method = _text(entry['method']) ?? 'metode';
          final amount = entry['amount'];
          return amount == null ? method : '$method: $amount';
        })
        .join(', ');
    if (split != null && split.isNotEmpty) return split;
    return _text(payload['paymentMethod']) ?? 'Tidak tercatat';
  }

  String get readableReason {
    final lower = error.toLowerCase();
    if (lower.contains('pilihan tambahan wajib belum dipilih')) {
      return 'Item masuk melalui jalur yang melewati pilihan wajib. Periksa '
          'nama item dan pilihan yang tercatat sebelum mencoba ulang.';
    }
    if (lower.contains('till sudah ditutup') ||
        lower.contains('shift pembayaran sudah ditutup')) {
      return 'Till pada transaksi sudah ditutup di server. Bandingkan ID till '
          'transaksi dengan till aktif sebelum mencoba ulang.';
    }
    if (lower.contains('belum melunasi total resmi server')) {
      return 'Total transaksi perangkat berbeda dengan total resmi server. '
          'Periksa pajak, layanan, promo, dan rincian pembayaran.';
    }
    if (lower.contains('created_by harus') || lower.contains('42501')) {
      return 'Sesi pengguna atau hak akses tidak sesuai dengan pembuat '
          'transaksi. Login kembali sebagai kasir pembuat transaksi.';
    }
    if (lower.contains('23514') || lower.contains('constraint')) {
      return 'Data transaksi tidak memenuhi aturan server dan perlu diperiksa '
          'sebelum dikirim ulang.';
    }
    if (lower.contains('harga item') ||
        lower.contains('harga katalog') ||
        lower.contains('unit_price')) {
      return 'Katalog berubah setelah transaksi dibuat offline. Transaksi '
          'tetap disimpan, tetapi harga/item harus ditinjau sebelum retry.';
    }
    return 'Server menolak transaksi. Salin detail ini untuk pemeriksaan lebih '
        'lanjut sebelum mencoba ulang.';
  }

  String get clipboardText {
    final lines = <String>[
      'Diagnostik transaksi ditolak',
      'Nomor lokal: $localReference',
      'ID order lokal: ${_text(payload['clientOrderId']) ?? '-'}',
      'ID till: ${shiftId ?? '-'}',
      if (originalShiftId != null) 'ID till asal: $originalShiftId',
      'Waktu transaksi: ${createdAt ?? '-'}',
      'Waktu ditolak: ${failedAt.isEmpty ? '-' : failedAt}',
      'ID kasir: ${createdBy ?? '-'}',
      'Metode pembayaran: $paymentSummary',
      ..._itemDiagnosticLines(),
      if (shiftStartedAt != null) 'Till mulai: $shiftStartedAt',
      if (shiftVerifiedAt != null) 'Till diverifikasi: $shiftVerifiedAt',
      if (shiftSource != null) 'Sumber till: $shiftSource',
      'Penjelasan: $readableReason',
      'Pesan server: ${error.isEmpty ? '-' : error}',
    ];
    return lines.join('\n');
  }

  List<String> _itemDiagnosticLines() {
    final items = payload['items'];
    if (items is! List || items.isEmpty) return const ['Item: -'];
    return items.whereType<Map>().map((item) {
      final name = _text(item['name']) ?? _text(item['menuItemId']) ?? 'Item';
      final quantity = item['quantity'] ?? 1;
      final extras =
          (item['extras'] as List?)
              ?.whereType<Map>()
              .map(
                (extra) =>
                    _text(extra['optionName']) ??
                    _text(extra['menuExtraOptionId']),
              )
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .join(', ') ??
          '';
      final optionText = extras.isEmpty ? 'tanpa pilihan' : extras;
      return 'Item: $name × $quantity · $optionText';
    }).toList();
  }

  static String? _text(dynamic value) {
    final result = value?.toString().trim();
    return result == null || result.isEmpty ? null : result;
  }
}

/// Antrean transaksi yang dibuat saat offline, menunggu disinkron ke server.
///
/// Dua box:
/// - [boxName] — antrean aktif yang akan dicoba sinkron.
/// - [deadBoxName] — dead-letter: transaksi yang DITOLAK server (validasi/RLS/
///   constraint). Dipindah ke sini agar TIDAK memblok antrean (head-of-line
///   blocking) dan tidak hilang diam-diam — bisa dicoba ulang manual dari UI.
class OfflineQueueService {
  OfflineQueueService._();
  static final OfflineQueueService instance = OfflineQueueService._();

  static const boxName = 'offline_orders_secure_v1';
  static const deadBoxName = 'offline_orders_dead_secure_v1';
  static const legacyBoxName = 'offline_orders';
  static const legacyDeadBoxName = 'offline_orders_dead';

  /// Jumlah transaksi yang belum tersinkron (untuk badge di UI).
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// Jumlah transaksi yang ditolak server & butuh perhatian (dead-letter).
  final ValueNotifier<int> deadCount = ValueNotifier<int>(0);

  Box get _box => Hive.box(boxName);
  Box? get _deadBox =>
      Hive.isBoxOpen(deadBoxName) ? Hive.box(deadBoxName) : null;

  void init() => _refresh();

  void _refresh() {
    pendingCount.value = _box.length;
    deadCount.value = _deadBox?.length ?? 0;
  }

  Future<void> enqueue(Map<String, dynamic> payload) async {
    // Validasi sebelum commit lokal. Transaksi yang tidak mungkin diterima
    // server tidak boleh terlihat berhasil disimpan (dan kemudian dicetak)
    // hanya untuk berakhir di dead-letter ketika koneksi pulih.
    validateOfflineQueuePayload(payload);
    await _box.add(jsonEncode(payload));
    _refresh();
  }

  /// Perbarui metadata sebuah order yang sudah aman di outbox. Digunakan
  /// setelah tiket dapur lokal benar-benar tercetak/terantre, karena order
  /// wajib disimpan ke disk lebih dulu sebelum byte dikirim ke printer.
  Future<Map<String, dynamic>?> updateByClientOrderId(
    String clientOrderId,
    Map<String, dynamic> changes,
  ) async {
    if (!Hive.isBoxOpen(boxName) || clientOrderId.isEmpty) return null;
    for (final entry in _box.toMap().entries) {
      try {
        final decoded = jsonDecode(entry.value as String);
        if (decoded is! Map || decoded['clientOrderId'] != clientOrderId) {
          continue;
        }
        final updated = <String, dynamic>{
          ...decoded.cast<String, dynamic>(),
          ...changes,
        };
        validateOfflineQueuePayload(updated);
        await _box.put(entry.key, jsonEncode(updated));
        _refresh();
        return updated;
      } catch (_) {
        // Record korup ditangani jalur sync/dead-letter; jangan mengubah
        // record lain hanya karena satu payload tidak dapat dibaca.
      }
    }
    return null;
  }

  /// Snapshot satu order outbox tanpa melakukan mutasi.
  Map<String, dynamic>? findByClientOrderId(String clientOrderId) {
    if (!Hive.isBoxOpen(boxName) || clientOrderId.isEmpty) return null;
    for (final entry in all()) {
      if (entry.value['clientOrderId'] == clientOrderId) {
        return Map<String, dynamic>.from(entry.value);
      }
    }
    return null;
  }

  /// Semua transaksi pending: (key Hive, payload).
  /// Aman dipanggil sebelum box dibuka (mis. saat test) → kembalikan kosong.
  List<MapEntry<dynamic, Map<String, dynamic>>> all() {
    if (!Hive.isBoxOpen(boxName)) return [];
    return _box.toMap().entries.map((e) {
      try {
        final decoded = jsonDecode(e.value as String);
        if (decoded is! Map) {
          throw const FormatException('Payload antrean bukan object JSON');
        }
        return MapEntry(e.key, decoded.cast<String, dynamic>());
      } catch (error) {
        // Jangan biarkan satu record Hive korup menggagalkan pembacaan seluruh
        // antrean. SyncService akan memindahkan sentinel ini ke dead-letter,
        // lengkap dengan data mentah untuk diagnosis manual.
        return MapEntry(e.key, <String, dynamic>{
          '_offlineQueueCorrupt': true,
          '_offlineQueueParseError': error.toString(),
          '_offlineQueueRaw': e.value.toString(),
        });
      }
    }).toList();
  }

  Future<void> remove(dynamic key) async {
    await _box.delete(key);
    _refresh();
  }

  /// Pindahkan satu transaksi ke dead-letter (ditolak server, bukan sekadar
  /// offline). Tetap menyimpan payload + alasan agar bisa dicoba ulang manual.
  Future<void> moveToDeadLetter(
    dynamic key,
    String error, {
    Map<String, dynamic>? payloadOverride,
  }) async {
    final dead = _deadBox;
    final raw = _box.get(key);
    // Jangan pernah menghapus transaksi aktif bila box dead-letter belum siap
    // atau record sumber sudah tidak ada. Penghapusan hanya aman dilakukan
    // setelah salinan diagnostik benar-benar berhasil ditulis.
    if (dead == null || raw == null) {
      _refresh();
      return;
    }
    Map<String, dynamic> payload = payloadOverride ?? <String, dynamic>{};
    if (payloadOverride == null) {
      try {
        final decoded = jsonDecode(raw as String);
        payload = decoded is Map
            ? decoded.cast<String, dynamic>()
            : <String, dynamic>{'_offlineQueueRaw': raw.toString()};
      } catch (_) {
        payload = <String, dynamic>{'_offlineQueueRaw': raw.toString()};
      }
    }
    await dead.add(
      jsonEncode({
        'error': error,
        'failedAt': DateTime.now().toIso8601String(),
        'payload': payload,
      }),
    );
    // Data finansial tidak boleh dihapus otomatis. Entri dead-letter hanya
    // boleh hilang setelah berhasil disinkron atau dibuang secara eksplisit
    // oleh pengguna. Batas jumlah di sini dahulu dapat menghapus transaksi
    // tertua secara diam-diam ketika perangkat lama tidak pernah diperiksa.
    await _box.delete(key);
    _refresh();
  }

  /// Pulihkan entri yang dahulu salah diklasifikasikan sebagai penolakan
  /// permanen, padahal penyebabnya hanya sesi login belum pulih atau transaksi
  /// sedang dicoba oleh akun kasir yang berbeda.
  ///
  /// Payload tetap berada di antrean aktif dan [SyncService] akan menahannya
  /// sampai akun pembuat transaksi kembali login. Penolakan bisnis seperti
  /// harga/constraint tetap berada di dead-letter untuk ditinjau manual.
  Future<int> retryRecoverableDeadLetters() async {
    final dead = _deadBox;
    if (dead == null) return 0;
    var recovered = 0;
    for (final entry in dead.toMap().entries) {
      Map<String, dynamic> env;
      try {
        env = jsonDecode(entry.value as String) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final error = (env['error'] as String? ?? '').toLowerCase();
      if (!_isRecoverableStoredError(error)) continue;
      final payload = (env['payload'] as Map?)?.cast<String, dynamic>();
      if (payload == null) continue;
      try {
        validateOfflineQueuePayload(payload);
      } on OfflineQueuePayloadException {
        // Jangan memindahkan payload legacy/rusak ke antrean aktif hanya
        // karena pesan error lamanya terlihat seperti masalah autentikasi.
        // Record tetap berada di dead-letter agar bisa didiagnosis operator.
        continue;
      }
      await _box.add(jsonEncode(payload));
      await dead.delete(entry.key);
      recovered++;
    }
    if (recovered > 0) _refresh();
    return recovered;
  }

  bool _isRecoverableStoredError(String error) {
    return error.contains('pgrst301') ||
        error.contains('pgrst302') ||
        error.contains('jwt expired') ||
        error.contains('invalid jwt') ||
        error.contains('token has expired') ||
        error.contains('not authenticated') ||
        error.contains('created_by harus merupakan pengguna yang sedang login');
  }

  /// Isi dead-letter untuk ditampilkan di UI: (key, error, failedAt, payload).
  List<DeadLetterDiagnostic> deadLetters() {
    final dead = _deadBox;
    if (dead == null) return [];
    return dead.toMap().entries.map((e) {
      Map<String, dynamic> env;
      try {
        env = jsonDecode(e.value as String) as Map<String, dynamic>;
      } catch (error) {
        // Tetap tampilkan record yang rusak kepada operator. Sebelumnya record
        // ini dipertahankan di Hive, tetapi UI menerima error/payload kosong
        // sehingga kasusnya sulit dibedakan dari transaksi tanpa metadata.
        env = <String, dynamic>{
          'error': 'Record dead-letter lokal rusak: $error',
          'payload': <String, dynamic>{'_offlineDeadRaw': e.value.toString()},
        };
      }
      return DeadLetterDiagnostic(
        key: e.key,
        error: (env['error'] as String?) ?? '',
        failedAt: (env['failedAt'] as String?) ?? '',
        payload:
            (env['payload'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
      );
    }).toList();
  }

  /// Kembalikan hanya satu dead-letter ke antrean aktif. Retry per transaksi
  /// mencegah order lain ikut dikirim ulang ketika operator sedang memeriksa
  /// satu kasus tertentu.
  Future<bool> retryDeadLetter(dynamic key) async {
    final dead = _deadBox;
    if (dead == null) return false;
    final raw = dead.get(key);
    if (raw == null) return false;
    try {
      final env = jsonDecode(raw as String) as Map<String, dynamic>;
      final payload = (env['payload'] as Map?)?.cast<String, dynamic>();
      if (payload == null) return false;
      validateOfflineQueuePayload(payload);
      await _box.add(jsonEncode(payload));
      await dead.delete(key);
      _refresh();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Kembalikan SEMUA dead-letter ke antrean aktif untuk dicoba ulang.
  /// Caller yang memicu sync setelahnya (hindari import silang).
  Future<void> retryAllDeadLetters() async {
    final dead = _deadBox;
    if (dead == null) return;
    for (final entry in dead.toMap().entries) {
      Map<String, dynamic> env;
      try {
        env = jsonDecode(entry.value as String) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final payload = (env['payload'] as Map?)?.cast<String, dynamic>();
      if (payload == null) continue;
      try {
        validateOfflineQueuePayload(payload);
      } on OfflineQueuePayloadException {
        // Retry massal tidak boleh membuat record invalid berputar terus
        // antara antrean aktif dan dead-letter.
        continue;
      }
      await _box.add(jsonEncode(payload));
      // Hapus per entri hanya setelah payload tersebut berhasil disalin.
      // Record dead-letter yang korup tetap disimpan untuk diagnosis manual.
      await dead.delete(entry.key);
    }
    _refresh();
  }

  /// Buang satu dead-letter permanen (kasir memutuskan tidak menyinkron).
  Future<void> discardDeadLetter(dynamic key) async {
    await _deadBox?.delete(key);
    _refresh();
  }
}

String? _optionalPayloadString(Map<String, dynamic> source, String key) {
  final value = source[key];
  if (value == null) return null;
  if (value is String && value.trim().isNotEmpty) return value;
  throw OfflineQueuePayloadException('Field antrean $key tidak valid');
}

String _requiredPayloadString(Map<String, dynamic> source, String key) {
  final value = _optionalPayloadString(source, key);
  if (value == null) {
    throw OfflineQueuePayloadException('Field antrean $key wajib diisi');
  }
  return value;
}

/// Memastikan transaksi lokal lengkap sebelum disimpan atau dikirim.
///
/// Fungsi ini tetap dipanggil lagi saat sinkronisasi untuk melindungi data dari
/// versi aplikasi lama, kerusakan penyimpanan, atau payload yang pernah ditulis
/// sebelum validasi saat enqueue tersedia.
void validateOfflineQueuePayload(Map<String, dynamic> payload) {
  if (payload['_offlineQueueCorrupt'] == true) {
    throw OfflineQueuePayloadException(
      'Record antrean tidak dapat dibaca: '
      '${payload['_offlineQueueParseError'] ?? 'format tidak dikenal'}',
    );
  }

  final kind = _requiredPayloadString(payload, 'kind');
  if (kind != 'draft' && kind != 'confirmed' && kind != 'paid') {
    throw const OfflineQueuePayloadException(
      'Jenis transaksi antrean tidak didukung',
    );
  }
  _requiredPayloadString(payload, 'clientOrderId');
  _requiredPayloadString(payload, 'outletId');
  final orderType = _requiredPayloadString(payload, 'orderType');
  if (!OrderType.values.any((value) => value.value == orderType)) {
    throw const OfflineQueuePayloadException(
      'Jenis order antrean tidak didukung',
    );
  }
  final createdAt = _requiredPayloadString(payload, 'createdAt');
  if (DateTime.tryParse(createdAt) == null) {
    throw const OfflineQueuePayloadException(
      'Waktu transaksi antrean tidak valid',
    );
  }
  final paidAt = _optionalPayloadString(payload, 'paidAt');
  if (paidAt != null && DateTime.tryParse(paidAt) == null) {
    throw const OfflineQueuePayloadException(
      'Waktu pembayaran antrean tidak valid',
    );
  }
  _requiredPayloadString(payload, 'createdBy');
  _optionalPayloadString(payload, 'replacesOrderId');
  _optionalPayloadString(payload, 'loyaltyMemberId');

  final items = payload['items'];
  if (items is! List || items.isEmpty || items.any((item) => item is! Map)) {
    throw const OfflineQueuePayloadException(
      'Field antrean items harus berisi daftar object',
    );
  }
  for (final rawItem in items) {
    final item = Map<String, dynamic>.from(rawItem as Map);
    _requiredPayloadString(item, 'menuItemId');
    _validatePositiveInteger(
      item['quantity'],
      'Kuantitas item antrean tidak valid',
    );
    _validateNonNegativeFiniteNumber(
      item['unitPrice'],
      'Harga item antrean tidak valid',
    );
    _validateNonNegativeFiniteNumber(
      item['subtotal'],
      'Subtotal item antrean tidak valid',
    );
    final extras = item['extras'];
    if (extras != null) {
      if (extras is! List || extras.any((extra) => extra is! Map)) {
        throw const OfflineQueuePayloadException(
          'Rincian ekstra item antrean tidak valid',
        );
      }
      for (final rawExtra in extras) {
        final extra = Map<String, dynamic>.from(rawExtra as Map);
        _requiredPayloadString(extra, 'menuExtraOptionId');
        final price = extra['price'];
        if (price != null) {
          _validateNonNegativeFiniteNumber(
            price,
            'Harga ekstra item antrean tidak valid',
          );
        }
      }
    }
  }

  // Subtotal dan total selalu dibentuk oleh keranjang. Field finansial lain
  // tetap opsional agar antrean dari versi lama masih bisa dipulihkan.
  for (final key in const ['subtotal', 'total']) {
    _validateNonNegativeFiniteNumber(
      payload[key],
      'Nilai $key pada antrean tidak valid',
    );
  }
  for (final key in const [
    'discountAmount',
    'taxAmount',
    'serviceCharge',
    'loyaltyDiscount',
  ]) {
    final value = payload[key];
    if (value != null) {
      _validateNonNegativeFiniteNumber(
        value,
        'Nilai $key pada antrean tidak valid',
      );
    }
  }
  final redeemedPoints = payload['redeemedPoints'];
  if (redeemedPoints != null) {
    _validateNonNegativeInteger(
      redeemedPoints,
      'Nilai redeemedPoints pada antrean tidak valid',
    );
  }
  final rounding = payload['rounding'];
  if (rounding != null && (rounding is! num || !rounding.isFinite)) {
    throw const OfflineQueuePayloadException(
      'Nilai rounding pada antrean tidak valid',
    );
  }

  final payments = payload['payments'];
  if (payments is List && payments.isNotEmpty) {
    for (final payment in payments) {
      if (payment is! Map) {
        throw const OfflineQueuePayloadException(
          'Rincian split payment tidak valid',
        );
      }
      final mappedPayment = Map<String, dynamic>.from(payment);
      final method = _requiredPayloadString(mappedPayment, 'method');
      _validatePaymentMethod(method, context: 'split payment');
      _requiredPayloadString(mappedPayment, 'idempotencyKey');
      _validatePositiveFiniteNumber(
        mappedPayment['amount'],
        'Nominal split payment tidak valid',
      );
      final splitPaidAt = _optionalPayloadString(mappedPayment, 'paidAt');
      if (splitPaidAt != null && DateTime.tryParse(splitPaidAt) == null) {
        throw const OfflineQueuePayloadException(
          'Waktu split payment tidak valid',
        );
      }
      _optionalPayloadString(mappedPayment, 'paidAtClockSource');
    }
    if (kind == 'draft' || kind == 'confirmed') return;
    _requiredPayloadString(payload, 'shiftId');
    return;
  }

  if (kind == 'draft' || kind == 'confirmed') return;
  _requiredPayloadString(payload, 'shiftId');

  final paymentMethod = _requiredPayloadString(payload, 'paymentMethod');
  _validatePaymentMethod(paymentMethod, context: 'pembayaran antrean');
  _requiredPayloadString(payload, 'idempotencyKey');
  _validatePositiveFiniteNumber(
    payload['amount'],
    'Nominal pembayaran antrean tidak valid',
  );
}

void _validatePaymentMethod(String method, {required String context}) {
  if (!PaymentMethod.values.any((value) => value.value == method)) {
    throw OfflineQueuePayloadException(
      'Metode pembayaran $context tidak valid',
    );
  }
}

void _validatePositiveFiniteNumber(Object? value, String message) {
  if (value is num && value.isFinite && value > 0) return;
  throw OfflineQueuePayloadException(message);
}

void _validatePositiveInteger(Object? value, String message) {
  if (value is int && value > 0) return;
  if (value is num && value.isFinite && value > 0 && value == value.round()) {
    return;
  }
  throw OfflineQueuePayloadException(message);
}

void _validateNonNegativeInteger(Object? value, String message) {
  if (value is int && value >= 0) return;
  if (value is num && value.isFinite && value >= 0 && value == value.round()) {
    return;
  }
  throw OfflineQueuePayloadException(message);
}

void _validateNonNegativeFiniteNumber(Object? value, String message) {
  if (value is num && value.isFinite && value >= 0) return;
  throw OfflineQueuePayloadException(message);
}

class OfflineQueuePayloadException implements Exception {
  const OfflineQueuePayloadException(this.message);

  final String message;

  @override
  String toString() => 'OfflineQueuePayloadException: $message';
}

import 'package:flutter/material.dart';
import '../../data/datasources/pos_datasource.dart';
import '../../../../core/widgets/app_toast.dart';

enum TillOutcome { resolved, none, cancelled }

class TillResult {
  final TillOutcome outcome;
  final String? shiftId;
  final bool usedCache;
  final Map<String, dynamic>? snapshot;

  const TillResult(
    this.outcome, [
    this.shiftId,
    this.usedCache = false,
    this.snapshot,
  ]);
  static const none = TillResult(TillOutcome.none);
  static const cancelled = TillResult(TillOutcome.cancelled);
}

/// Tentukan shift tujuan pembayaran untuk penjual
/// [sellerId] di [outletId]:
/// - kasir dengan shift sendiri → shiftnya dipilih otomatis,
/// - tanpa shift (owner/admin): 1 till terbuka → auto, >1 → pilih, 0 → warn.
/// [requireOwnShift] wajib true untuk role kasir agar ia tidak bisa menumpang
/// shift kasir lain ketika login hanya untuk melihat aplikasi.
///
/// Dipakai di semua alur bayar tunai (walk-in, bagi tagihan, bayar order
/// existing) agar kas selalu nempel ke laci penerima uang.
/// [fromCache] — pakai daftar shift yang sudah dihangatkan (tanpa jaringan).
/// Dipakai saat Bayar ditekan, karena struk harus keluar dalam ~0.1 detik dan
/// satu round-trip di sini saja sudah menggagalkannya. Bila cache ternyata
/// kosong (penghangatan gagal), tetap jatuh ke jaringan: lebih baik kasir
/// menunggu sesaat daripada kas tunai kehilangan atribusi till.
Future<TillResult> resolveCashTill(
  BuildContext context, {
  required String outletId,
  required String sellerId,
  bool fromCache = false,
  bool isCash = true,
  bool requireOwnShift = false,
}) async {
  final ds = PosDatasource();
  List<Map<String, dynamic>> open = fromCache
      ? ds.cachedOpenShifts(outletId)
      : const [];
  var usedCache = fromCache && open.isNotEmpty;
  if (open.isEmpty) {
    try {
      open = await ds.fetchOpenShifts(outletId);
      usedCache = false;
    } catch (_) {
      // Status koneksi dapat terlambat berubah beberapa detik. Bila request
      // server gagal, tetap amankan transaksi memakai snapshot lokal terakhir;
      // server akan melakukan rekonsiliasi shift saat replay.
      open = ds.cachedOpenShifts(outletId);
      usedCache = true;
      if (open.isEmpty) return TillResult.none;
    }
  }
  final own = open.where((s) => s['kasir_id'] == sellerId).toList();
  if (own.isNotEmpty) {
    return TillResult(
      TillOutcome.resolved,
      own.first['id'] as String?,
      usedCache,
      Map<String, dynamic>.from(own.first),
    );
  }
  if (requireOwnShift) {
    if (context.mounted) {
      AppToast.info(
        context,
        'Kasir belum dibuka. Buka Kasir dari menu sebelum menerima pembayaran.',
      );
    }
    return TillResult.none;
  }
  if (open.isEmpty) {
    if (context.mounted) {
      AppToast.info(
        context,
        'Tak ada shift kasir terbuka — pembayaran belum dapat diproses.',
      );
    }
    return TillResult.none;
  }
  if (open.length == 1) {
    return TillResult(
      TillOutcome.resolved,
      open.first['id'] as String?,
      usedCache,
      Map<String, dynamic>.from(open.first),
    );
  }
  if (!context.mounted) return TillResult.cancelled;
  final picked = await _pickTill(context, open, isCash: isCash);
  if (picked == null) return TillResult.cancelled;
  Map<String, dynamic>? selected;
  for (final entry in open) {
    if (entry['id'] == picked) {
      selected = entry;
      break;
    }
  }
  return TillResult(
    TillOutcome.resolved,
    picked,
    usedCache,
    selected == null ? null : Map<String, dynamic>.from(selected),
  );
}

Future<String?> _pickTill(
  BuildContext context,
  List<Map<String, dynamic>> shifts, {
  required bool isCash,
}) {
  return showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              isCash
                  ? 'Kas tunai masuk ke till mana?'
                  : 'Pembayaran masuk ke shift mana?',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          for (final s in shifts)
            ListTile(
              leading: const Icon(Icons.point_of_sale_outlined),
              title: Text('Kasir ${s['kasir_name']}'),
              onTap: () => Navigator.pop(ctx, s['id'] as String),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

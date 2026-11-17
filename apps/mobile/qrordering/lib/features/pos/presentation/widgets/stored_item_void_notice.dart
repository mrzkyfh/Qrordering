import 'package:flutter/material.dart';

/// Persisted items are changed only by the existing server-approved Void Item
/// flow in order details. Never approve a local deletion with a client flag.
Future<void> showStoredItemVoidNotice(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Kode void diperlukan'),
    content: const Text(
      'Item ini sudah tersimpan dalam pesanan. Untuk menghapus atau mengurangi '
      'jumlahnya, buka Daftar Order → detail pesanan → Void Item, lalu masukkan '
      'PIN persetujuan atasan. Item tambahan yang belum disimpan tetap bisa dikoreksi.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Mengerti'),
      ),
    ],
  ),
);

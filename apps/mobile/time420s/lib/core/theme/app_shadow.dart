import 'package:flutter/material.dart';

/// Token shadow — netral & halus (Design System 2026).
///
/// Hanya 3 level. TIDAK ADA shadow berwarna brand (merah) — shadow selalu
/// hitam transparan agar terasa premium & tenang.
class AppShadow {
  AppShadow._();

  /// Kartu yang "mengambang" di canvas.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0A000000), // black @ ~4%
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];

  /// Kartu kecil / elemen ringan.
  static const List<BoxShadow> sm = [
    BoxShadow(
      color: Color(0x0F000000), // black @ ~6%
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];

  /// Dialog, bottom sheet, floating element.
  static const List<BoxShadow> modal = [
    BoxShadow(
      color: Color(0x1F000000), // black @ ~12%
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];
}

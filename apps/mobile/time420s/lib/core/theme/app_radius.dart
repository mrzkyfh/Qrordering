import 'package:flutter/widgets.dart';

/// Token radius — hanya 4 nilai + pill (Design System 2026).
///
/// Standar: kartu/sheet = [lg] (16) · tombol/field = [md] (12) ·
/// chip/kotak ikon/badge = [sm] (8) · dialog/bottom-sheet atas = [xl] (20).
class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double full = 999;

  // ── BorderRadius siap pakai ─────────────────────────────────────────────
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));

  /// Radius hanya di sisi atas (untuk bottom sheet).
  static const BorderRadius topXl =
      BorderRadius.vertical(top: Radius.circular(xl));
}

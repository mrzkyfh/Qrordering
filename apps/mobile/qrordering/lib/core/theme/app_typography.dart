import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Skala tipografi semantik — Plus Jakarta Sans (Design System 2026).
///
/// Targetkan 9 gaya, bukan 22 ukuran liar. Pakai gaya ini alih-alih
/// `TextStyle(fontSize: ...)` manual agar konsisten lintas-layar.
///
/// Catatan: gaya sudah memakai Plus Jakarta Sans secara eksplisit, jadi aman
/// dipakai di mana pun tanpa bergantung pada inheritance theme.
class AppText {
  AppText._();

  static TextStyle _base(
    double size,
    FontWeight weight, {
    double? letterSpacing,
    Color? color,
    double? height,
  }) =>
      GoogleFonts.plusJakartaSans(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? AppColors.textPrimary,
        height: height,
      );

  // ── Display / angka besar ───────────────────────────────────────────────
  static TextStyle get displayLg => _base(30, FontWeight.w800, letterSpacing: -1.0);
  static TextStyle get displaySm => _base(24, FontWeight.w800, letterSpacing: -0.6);

  // ── Heading ─────────────────────────────────────────────────────────────
  static TextStyle get h1 => _base(20, FontWeight.w700, letterSpacing: -0.4);
  static TextStyle get h2 => _base(17, FontWeight.w700, letterSpacing: -0.3);
  static TextStyle get h3 => _base(15, FontWeight.w600, letterSpacing: -0.2);

  // ── Body ────────────────────────────────────────────────────────────────
  static TextStyle get bodyLg => _base(14, FontWeight.w400, height: 1.4);
  static TextStyle get body => _base(13, FontWeight.w400, height: 1.4);
  static TextStyle get caption =>
      _base(12, FontWeight.w400, color: AppColors.textSecondary);

  // ── Label / overline (UPPERCASE) ────────────────────────────────────────
  static TextStyle get label => _base(11, FontWeight.w700,
      letterSpacing: 0.6, color: AppColors.textSecondary);

  // ── Harga ── (HITAM tebal — bukan merah; merah hanya untuk Total akhir) ──
  static TextStyle get price => _base(15, FontWeight.w800, letterSpacing: -0.2);
}

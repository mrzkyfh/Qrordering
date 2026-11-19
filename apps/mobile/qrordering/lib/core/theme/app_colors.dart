import 'package:flutter/material.dart';

/// Design System 2026 — POS premium (Stripe / Linear / Square POS vibe).
///
/// Aturan komposisi warna:
///   70% netral (slate / gray)  ·  20% surface & border  ·  10% teal brand
///
/// Teal (#0F766E) untuk CTA utama dan menu/tab aktif. Merah hanya untuk
/// status kritis seperti gagal, habis, batal, dan void.
/// Selebihnya gunakan palet netral slate agar terasa modern & data-focused.
class AppColors {
  AppColors._();

  // ─── Brand mejaku ─────────────────────────────────────────────────────────
  static const primary = Color(0xFF0F766E);
  static const primaryDark = Color(0xFF115E59);
  static const primaryLight = Color(0xFF14B8A6);
  static const primarySubtle = Color(0xFFCCFBF1);

  // ─── Netral / Slate (mayoritas UI) ────────────────────────────────────────
  // Latar aplikasi — slate sangat terang, kartu putih "mengambang" di atasnya.
  static const background = Color(0xFFF7F8F9);
  static const canvas = Color(0xFFF7F8F9);
  // Surface untuk highlight halus / selected state (netral, BUKAN pink).
  static const backgroundLight = Color(0xFFF1F5F9); // slate-100
  static const backgroundDark = Color(0xFFE2E8F0); // slate-200

  // Surface & card
  static const surface = Color(0xFFFFFFFF);
  static const surfaceVariant = Color(0xFFF1F5F9); // slate-100 (input fill)

  // Slate scale (dipakai untuk hierarki & aksen netral)
  static const slate50 = Color(0xFFF8FAFC);
  static const slate100 = Color(0xFFF1F5F9);
  static const slate200 = Color(0xFFE2E8F0);
  static const slate300 = Color(0xFFCBD5E1);
  static const slate400 = Color(0xFF94A3B8);
  static const slate500 = Color(0xFF64748B);
  static const slate600 = Color(0xFF475569);
  static const slate700 = Color(0xFF334155);
  static const slate800 = Color(0xFF1E293B);
  static const slate900 = Color(0xFF0F172A);

  // Text
  static const textPrimary = Color(0xFF191D21);
  static const textSecondary = Color(0xFF6F7782);
  static const textDisabled = Color(0xFF94A3B8); // slate-400
  static const textOnPrimary = Color(0xFFFFFFFF);
  static const textOnTeal = Color(0xFFFFFFFF);

  // Border / divider
  static const border = Color(0xFFE5E7EB);
  static const borderStrong = Color(0xFFCBD5E1);

  static const teal = Color(0xFF0F766E);
  static const tealLight = Color(0xFF14B8A6);
  static const tealDark = Color(0xFF115E59);
  static const secondary = Color(0xFFF59E0B);

  static const accent = Color(0xFFCCFBF1);
  static const accentForeground = Color(0xFF115E59);

  // ─── Status semantik ──────────────────────────────────────────────────────
  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const info = Color(0xFF3B82F6);
  static const error = Color(0xFFDC2626);

  // Order status — Draft=Gray · Diproses=Blue · Disajikan=Indigo · Selesai=Green · Void=Red
  static const statusDraft = Color(0xFF64748B); // slate-500
  static const statusConfirmed = Color(0xFF3B82F6); // blue (diproses)
  static const statusPreparing = Color(0xFF3B82F6); // blue (diproses)
  static const statusReady = Color(0xFF10B981); // green (siap)
  static const statusServed = Color(0xFF4F46E5); // indigo (disajikan)
  static const statusPaid = Color(0xFF10B981); // green (selesai)
  static const statusCancelled = Color(0xFFDC2626); // red (void)
  static const statusVoid = Color(0xFFDC2626); // red (void)

  // Table status
  static const tableAvailable = Color(0xFF10B981); // green
  static const tableOccupied = Color(0xFFDC2626); // red
  static const tableReserved = Color(0xFFF59E0B); // amber
  static const tableDirty = Color(0xFF64748B); // slate

  // ─── Palet halaman Penjualan (layout split) ───────────────────────────────
  // Netral spesifik desain
  static const salesCanvas = Color(0xFFF5F5F5);
  static const salesTopbarBorder = Color(0xFFEFEFEF);
  static const salesChipBg = Color(0xFFF5F5F5);
  static const salesHeaderBg = Color(0xFFFAFAFA);
  static const salesRowAlt = Color(0xFFFAFAFA);
  static const salesRowDivider = Color(0xFFF8F8F8);
  static const salesGroupDivider = Color(0xFFF0F0F0);
  static const salesTextDark = Color(0xFF111111);
  static const salesTextMid = Color(0xFF333333);
  static const salesTextGray = Color(0xFF666666);
  static const salesTextMuted = Color(0xFF888888);
  static const salesTextLight = Color(0xFF999999);
  static const salesTextFaint = Color(0xFFBBBBBB);
  static const salesTextFainter = Color(0xFFCCCCCC);
  // Stat boxes
  static const salesBoxSalesBg = Color(0xFFFFECEC);
  static const salesBoxSalesLabel = Color(0xFF115E59);
  static const salesBoxTrxBg = Color(0xFFEAF3DE);
  static const salesBoxTrxLabel = Color(0xFF27500A);
  static const salesBoxAvgBg = Color(0xFFFEF3C7);
  static const salesBoxAvgLabel = Color(0xFF92400E);
  // Filter / badge jenis
  static const salesAccentRed = Color(0xFF0F766E);
  static const salesDineInBg = Color(0xFFE6F1FB);
  static const salesDineInFg = Color(0xFF185FA5);
  static const salesOnlineBg = Color(0xFFEEEDFE);
  static const salesOnlineFg = Color(0xFF534AB7);
  static const salesKasirBg = Color(0xFFEAF3DE);
  static const salesKasirFg = Color(0xFF27500A);

  // ─── Modal detail tiket Dapur ─────────────────────────────────────────────
  static const ktIndigo = Color(0xFF4338CA);
  static const ktIndigoBg = Color(0xFFEEEDFE);
  // Badge status
  static const ktBadgeNewBg = Color(0xFFFCD34D);
  static const ktBadgeNewFg = Color(0xFF78350F);
  static const ktBadgeCookBg = Color(0xFFA78BFA);
  static const ktBadgeCookFg = Color(0xFF3B0764);
  static const ktBadgeReadyBg = Color(0xFF4ADE80);
  static const ktBadgeReadyFg = Color(0xFF14532D);
  // Timer (per ambang waktu)
  static const ktTimerGreen = Color(0xFF1D9E75);
  static const ktTimerGreenBg = Color(0xFFEAF3DE);
  static const ktTimerYellow = Color(0xFFD97706);
  static const ktTimerYellowBg = Color(0xFFFEF3C7);
  static const ktTimerRed = Color(0xFF0F766E);
  static const ktTimerRedBg = Color(0xFFFFECEC);
  static const ktTimerRedLabel = Color(0xFF115E59);
  // Surface & catatan
  static const ktInfoBg = Color(0xFFF8F8F8);
  static const ktTagBg = Color(0xFFF0F0F0);
  static const ktDivider = Color(0xFFF0F0F0);
  static const ktNoteBg = Color(0xFFFFFBEB);
  static const ktNoteBorder = Color(0xFFFDE68A);
  static const ktNoteLabel = Color(0xFF92400E);
  static const ktNoteText = Color(0xFF78350F);
  static const ktCloseBg = Color(0xFFF5F5F5);
  // Tombol aksi & footer
  static const ktBtnNew = Color(0xFF4338CA);
  static const ktBtnCook = Color(0xFF1D9E75);
  static const ktBtnServeBorder = Color(0xFF16A34A);
  static const ktCloseBtnBorder = Color(0xFFE0E0E0);
  static const ktCloseBtnText = Color(0xFF555555);
  // Teks netral
  static const ktText111 = Color(0xFF111111);
  static const ktText666 = Color(0xFF666666);
  static const ktText888 = Color(0xFF888888);
  static const ktText999 = Color(0xFF999999);
  static const ktTextBBB = Color(0xFFBBBBBB);

  // ─── Helper: tint sangat tipis dari sebuah warna status (untuk badge/chip) ─
  static Color tint(Color c) =>
      Color.alphaBlend(c.withValues(alpha: 0.10), surface);
}

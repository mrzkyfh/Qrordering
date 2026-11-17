import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';
import '../theme/app_colors.dart';

/// Tema bersama untuk seluruh input PIN (set PIN, verifikasi void/refund).
const _kPinTextStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w600,
  color: AppColors.textPrimary,
);

final PinTheme kPinTheme = PinTheme(
  width: 48,
  height: 52,
  textStyle: _kPinTextStyle,
  decoration: BoxDecoration(
    color: AppColors.background,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: AppColors.border),
  ),
);

final PinTheme kPinThemeFocused = kPinTheme.copyDecorationWith(
  border: Border.all(color: AppColors.primary, width: 1.6),
  borderRadius: BorderRadius.circular(10),
);

final PinTheme kPinThemeError = kPinTheme.copyDecorationWith(
  color: AppColors.error.withValues(alpha: 0.06),
  border: Border.all(color: AppColors.error),
  borderRadius: BorderRadius.circular(10),
);

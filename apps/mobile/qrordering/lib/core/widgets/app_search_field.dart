import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_typography.dart';

/// Search field seragam (filled slate, radius 12, ikon search di depan).
/// Satu gaya untuk semua layar (Daftar Order, Pengaturan, dll) agar konsisten.
class AppSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final double height;

  const AppSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.height = 40,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: AppText.body,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppText.body.copyWith(color: AppColors.textDisabled),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 18, color: AppColors.textDisabled),
          filled: true,
          fillColor: AppColors.surfaceVariant,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          border: const OutlineInputBorder(
            borderRadius: AppRadius.brMd,
            borderSide: BorderSide.none,
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: AppRadius.brMd,
            borderSide: BorderSide.none,
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: AppRadius.brMd,
            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

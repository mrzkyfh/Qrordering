import 'package:flutter/material.dart';

/// Tombol aksi order reusable (Detail / Proses / Sajikan / Bayar / Lunas / Batal).
/// Semua tombol: border-radius 8, height 30, fontSize 11 w500.
/// [onPressed] null → tombol nonaktif (mis. order offline).
class OrderButton extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color textColor;
  final Color? borderColor;
  final VoidCallback? onPressed;
  final IconData? icon;

  const OrderButton({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    required this.onPressed,
    this.borderColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: SizedBox(
        height: 30,
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: borderColor != null
                    ? Border.all(color: borderColor!, width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: textColor),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

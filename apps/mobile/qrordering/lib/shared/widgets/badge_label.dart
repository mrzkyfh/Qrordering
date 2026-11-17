import 'package:flutter/material.dart';

/// Badge label reusable (Dine In / Online / status order).
class BadgeLabel extends StatelessWidget {
  final String text;
  final Color backgroundColor;
  final Color textColor;
  final double borderRadius;
  final double fontSize;
  final EdgeInsets padding;

  const BadgeLabel({
    super.key,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
    this.borderRadius = 6,
    this.fontSize = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}

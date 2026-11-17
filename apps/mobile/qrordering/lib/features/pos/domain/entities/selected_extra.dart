import 'package:equatable/equatable.dart';

class SelectedExtra extends Equatable {
  final String menuExtraId;
  final String menuExtraOptionId;
  final String extraName;
  final String optionName;
  final double price;

  const SelectedExtra({
    required this.menuExtraId,
    required this.menuExtraOptionId,
    required this.extraName,
    required this.optionName,
    required this.price,
  });

  @override
  List<Object?> get props => [menuExtraId, menuExtraOptionId];
}
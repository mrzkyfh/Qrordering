import 'package:equatable/equatable.dart';
import 'enums.dart';

class Profile extends Equatable {
  final String id;
  final String? outletId;
  final String? outletName;
  final UserRole role;
  final String fullName;
  final String? phone;
  final String? avatarUrl;
  final bool isActive;
  final bool canRefund;
  final DateTime? lastLoginAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Profile({
    required this.id,
    this.outletId,
    this.outletName,
    required this.role,
    required this.fullName,
    this.phone,
    this.avatarUrl,
    required this.isActive,
    this.canRefund = true,
    this.lastLoginAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        outletId: json['outlet_id'] as String?,
        // Nama outlet dari join `outlets(name)` (nested) atau kolom langsung.
        outletName: (json['outlets'] as Map?)?['name'] as String? ??
            json['outlet_name'] as String?,
        role: UserRoleX.fromString(json['role'] as String),
        fullName: json['full_name'] as String,
        phone: json['phone'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        isActive: json['is_active'] as bool,
        canRefund: json['can_refund'] as bool? ?? true,
        lastLoginAt: json['last_login_at'] != null
            ? DateTime.parse(json['last_login_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Profile copyWith({
    String? outletId,
    String? outletName,
  }) =>
      Profile(
        id: id,
        outletId: outletId ?? this.outletId,
        outletName: outletName ?? this.outletName,
        role: role,
        fullName: fullName,
        phone: phone,
        avatarUrl: avatarUrl,
        isActive: isActive,
        canRefund: canRefund,
        lastLoginAt: lastLoginAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  @override
  List<Object?> get props =>
      [id, outletId, outletName, role, fullName, isActive, canRefund];
}

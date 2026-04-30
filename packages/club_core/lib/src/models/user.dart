import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'user_role.dart';

part 'user.g.dart';

@JsonSerializable()
class User extends Equatable {
  const User({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.role,
    required this.isActive,
    this.mustChangePassword = false,
    this.hasAvatar = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  final String userId;
  final String email;
  final String displayName;

  /// Authorization role. See [UserRole] + `authz/permissions.dart`.
  @JsonKey(fromJson: _roleFromJson, toJson: _roleToJson)
  final UserRole role;

  final bool isActive;

  /// When true, the next login must prompt the user to choose a new
  /// password before any other app state becomes accessible.
  final bool mustChangePassword;

  /// Whether this user has uploaded a profile picture.
  final bool hasAvatar;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Convenience check: is this user an admin-or-higher?
  bool get isAdmin => role.isAtLeast(UserRole.admin);

  /// Convenience check: is this user the server owner?
  bool get isOwner => role == UserRole.owner;

  Map<String, dynamic> toJson() => _$UserToJson(this);

  @override
  List<Object?> get props => [
    userId,
    email,
    displayName,
    role,
    isActive,
    mustChangePassword,
    hasAvatar,
    createdAt,
    updatedAt,
  ];
}

class UserCompanion {
  const UserCompanion({
    required this.userId,
    required this.email,
    required this.passwordHash,
    required this.displayName,
    this.role = UserRole.viewer,
    this.isActive = true,
    this.mustChangePassword = false,
  });

  final String userId;
  final String email;
  final String passwordHash;
  final String displayName;
  final UserRole role;
  final bool isActive;
  final bool mustChangePassword;
}

// JSON converters for the UserRole enum.
UserRole _roleFromJson(String value) => UserRole.fromString(value);
String _roleToJson(UserRole role) => role.name;

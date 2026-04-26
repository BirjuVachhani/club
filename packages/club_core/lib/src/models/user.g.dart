// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

User _$UserFromJson(Map<String, dynamic> json) => User(
  userId: json['userId'] as String,
  email: json['email'] as String,
  displayName: json['displayName'] as String,
  role: _roleFromJson(json['role'] as String),
  isActive: json['isActive'] as bool,
  mustChangePassword: json['mustChangePassword'] as bool? ?? false,
  hasAvatar: json['hasAvatar'] as bool? ?? false,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
  'userId': instance.userId,
  'email': instance.email,
  'displayName': instance.displayName,
  'role': _roleToJson(instance.role),
  'isActive': instance.isActive,
  'mustChangePassword': instance.mustChangePassword,
  'hasAvatar': instance.hasAvatar,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};

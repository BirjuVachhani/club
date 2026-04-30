// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'publisher_member.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PublisherMember _$PublisherMemberFromJson(Map<String, dynamic> json) =>
    PublisherMember(
      publisherId: json['publisherId'] as String,
      userId: json['userId'] as String,
      role: json['role'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$PublisherMemberToJson(PublisherMember instance) =>
    <String, dynamic>{
      'publisherId': instance.publisherId,
      'userId': instance.userId,
      'role': instance.role,
      'createdAt': instance.createdAt.toIso8601String(),
    };

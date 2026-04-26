// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'publisher.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Publisher _$PublisherFromJson(Map<String, dynamic> json) => Publisher(
  id: json['id'] as String,
  displayName: json['displayName'] as String,
  description: json['description'] as String?,
  websiteUrl: json['websiteUrl'] as String?,
  contactEmail: json['contactEmail'] as String?,
  verified: json['verified'] as bool? ?? false,
  createdBy: json['createdBy'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$PublisherToJson(Publisher instance) => <String, dynamic>{
  'id': instance.id,
  'displayName': instance.displayName,
  'description': instance.description,
  'websiteUrl': instance.websiteUrl,
  'contactEmail': instance.contactEmail,
  'verified': instance.verified,
  'createdBy': instance.createdBy,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};

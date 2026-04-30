// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Package _$PackageFromJson(Map<String, dynamic> json) => Package(
  name: json['name'] as String,
  publisherId: json['publisherId'] as String?,
  latestVersion: json['latestVersion'] as String?,
  latestPrerelease: json['latestPrerelease'] as String?,
  likesCount: (json['likesCount'] as num?)?.toInt() ?? 0,
  isDiscontinued: json['isDiscontinued'] as bool? ?? false,
  replacedBy: json['replacedBy'] as String?,
  isUnlisted: json['isUnlisted'] as bool? ?? false,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$PackageToJson(Package instance) => <String, dynamic>{
  'name': instance.name,
  'publisherId': instance.publisherId,
  'latestVersion': instance.latestVersion,
  'latestPrerelease': instance.latestPrerelease,
  'likesCount': instance.likesCount,
  'isDiscontinued': instance.isDiscontinued,
  'replacedBy': instance.replacedBy,
  'isUnlisted': instance.isUnlisted,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};

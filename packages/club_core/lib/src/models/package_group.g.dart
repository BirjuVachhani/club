// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_group.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageGroup _$PackageGroupFromJson(Map<String, dynamic> json) => PackageGroup(
  id: json['id'] as String,
  slug: json['slug'] as String,
  name: json['name'] as String,
  description: json['description'] as String?,
  ownerUserId: json['ownerUserId'] as String?,
  publisherId: json['publisherId'] as String?,
  createdBy: json['createdBy'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$PackageGroupToJson(PackageGroup instance) =>
    <String, dynamic>{
      'id': instance.id,
      'slug': instance.slug,
      'name': instance.name,
      'description': instance.description,
      'ownerUserId': instance.ownerUserId,
      'publisherId': instance.publisherId,
      'createdBy': instance.createdBy,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
    };

PackageGroupPackage _$PackageGroupPackageFromJson(Map<String, dynamic> json) =>
    PackageGroupPackage(
      groupId: json['groupId'] as String,
      packageName: json['packageName'] as String,
      position: (json['position'] as num).toInt(),
      addedBy: json['addedBy'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$PackageGroupPackageToJson(
  PackageGroupPackage instance,
) => <String, dynamic>{
  'groupId': instance.groupId,
  'packageName': instance.packageName,
  'position': instance.position,
  'addedBy': instance.addedBy,
  'createdAt': instance.createdAt.toIso8601String(),
};

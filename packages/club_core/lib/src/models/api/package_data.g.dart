// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_data.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageData _$PackageDataFromJson(Map<String, dynamic> json) => PackageData(
  name: json['name'] as String,
  isDiscontinued: json['isDiscontinued'] as bool?,
  replacedBy: json['replacedBy'] as String?,
  isUnlisted: json['isUnlisted'] as bool?,
  latest: VersionInfo.fromJson(json['latest'] as Map<String, dynamic>),
  latestPrerelease: json['latestPrerelease'] == null
      ? null
      : VersionInfo.fromJson(json['latestPrerelease'] as Map<String, dynamic>),
  versions: (json['versions'] as List<dynamic>)
      .map((e) => VersionInfo.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$PackageDataToJson(PackageData instance) =>
    <String, dynamic>{
      'name': instance.name,
      'isDiscontinued': instance.isDiscontinued,
      'replacedBy': instance.replacedBy,
      'isUnlisted': instance.isUnlisted,
      'latest': instance.latest,
      'latestPrerelease': instance.latestPrerelease,
      'versions': instance.versions,
    };

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pkg_options.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PkgOptions _$PkgOptionsFromJson(Map<String, dynamic> json) => PkgOptions(
  isDiscontinued: json['isDiscontinued'] as bool?,
  replacedBy: json['replacedBy'] as String?,
  isUnlisted: json['isUnlisted'] as bool?,
);

Map<String, dynamic> _$PkgOptionsToJson(PkgOptions instance) =>
    <String, dynamic>{
      'isDiscontinued': instance.isDiscontinued,
      'replacedBy': instance.replacedBy,
      'isUnlisted': instance.isUnlisted,
    };

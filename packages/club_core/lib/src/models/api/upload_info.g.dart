// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upload_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UploadInfo _$UploadInfoFromJson(Map<String, dynamic> json) => UploadInfo(
  url: json['url'] as String,
  fields: Map<String, String>.from(json['fields'] as Map),
);

Map<String, dynamic> _$UploadInfoToJson(UploadInfo instance) =>
    <String, dynamic>{'url': instance.url, 'fields': instance.fields};

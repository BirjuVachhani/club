// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'version_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

VersionInfo _$VersionInfoFromJson(Map<String, dynamic> json) => VersionInfo(
  version: json['version'] as String,
  retracted: json['retracted'] as bool?,
  pubspec: json['pubspec'] as Map<String, dynamic>,
  archiveUrl: json['archive_url'] as String?,
  archiveSha256: json['archive_sha256'] as String?,
  published: json['published'] == null
      ? null
      : DateTime.parse(json['published'] as String),
);

Map<String, dynamic> _$VersionInfoToJson(VersionInfo instance) =>
    <String, dynamic>{
      'version': instance.version,
      'retracted': instance.retracted,
      'pubspec': instance.pubspec,
      'archive_url': instance.archiveUrl,
      'archive_sha256': instance.archiveSha256,
      'published': instance.published?.toIso8601String(),
    };

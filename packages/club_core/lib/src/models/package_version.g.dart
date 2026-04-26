// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_version.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageVersion _$PackageVersionFromJson(Map<String, dynamic> json) =>
    PackageVersion(
      packageName: json['packageName'] as String,
      version: json['version'] as String,
      pubspecJson: json['pubspecJson'] as String,
      readmeContent: json['readmeContent'] as String?,
      changelogContent: json['changelogContent'] as String?,
      exampleContent: json['exampleContent'] as String?,
      examplePath: json['examplePath'] as String?,
      libraries: (json['libraries'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      binExecutables:
          (json['binExecutables'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      screenshots:
          (json['screenshots'] as List<dynamic>?)
              ?.map(
                (e) => PackageScreenshot.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const [],
      archiveSizeBytes: (json['archiveSizeBytes'] as num).toInt(),
      archiveSha256: json['archiveSha256'] as String,
      uploaderId: json['uploaderId'] as String?,
      publisherId: json['publisherId'] as String?,
      isRetracted: json['isRetracted'] as bool? ?? false,
      retractedAt: json['retractedAt'] == null
          ? null
          : DateTime.parse(json['retractedAt'] as String),
      isPrerelease: json['isPrerelease'] as bool? ?? false,
      dartSdkMin: json['dartSdkMin'] as String?,
      dartSdkMax: json['dartSdkMax'] as String?,
      flutterSdkMin: json['flutterSdkMin'] as String?,
      flutterSdkMax: json['flutterSdkMax'] as String?,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          const [],
      publishedAt: DateTime.parse(json['publishedAt'] as String),
    );

Map<String, dynamic> _$PackageVersionToJson(PackageVersion instance) =>
    <String, dynamic>{
      'packageName': instance.packageName,
      'version': instance.version,
      'pubspecJson': instance.pubspecJson,
      'readmeContent': instance.readmeContent,
      'changelogContent': instance.changelogContent,
      'exampleContent': instance.exampleContent,
      'examplePath': instance.examplePath,
      'libraries': instance.libraries,
      'binExecutables': instance.binExecutables,
      'screenshots': instance.screenshots,
      'archiveSizeBytes': instance.archiveSizeBytes,
      'archiveSha256': instance.archiveSha256,
      'uploaderId': instance.uploaderId,
      'publisherId': instance.publisherId,
      'isRetracted': instance.isRetracted,
      'retractedAt': instance.retractedAt?.toIso8601String(),
      'isPrerelease': instance.isPrerelease,
      'dartSdkMin': instance.dartSdkMin,
      'dartSdkMax': instance.dartSdkMax,
      'flutterSdkMin': instance.flutterSdkMin,
      'flutterSdkMax': instance.flutterSdkMax,
      'tags': instance.tags,
      'publishedAt': instance.publishedAt.toIso8601String(),
    };

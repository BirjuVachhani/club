// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'version_content.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

VersionContent _$VersionContentFromJson(Map<String, dynamic> json) =>
    VersionContent(
      package: json['package'] as String,
      version: json['version'] as String,
      readme: json['readme'] as String?,
      changelog: json['changelog'] as String?,
      example: json['example'] as String?,
      examplePath: json['examplePath'] as String?,
      binExecutables:
          (json['binExecutables'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      screenshots:
          (json['screenshots'] as List<dynamic>?)
              ?.map(
                (e) => VersionScreenshot.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const [],
    );

Map<String, dynamic> _$VersionContentToJson(VersionContent instance) =>
    <String, dynamic>{
      'package': instance.package,
      'version': instance.version,
      'readme': instance.readme,
      'changelog': instance.changelog,
      'example': instance.example,
      'examplePath': instance.examplePath,
      'binExecutables': instance.binExecutables,
      'screenshots': instance.screenshots,
    };

VersionScreenshot _$VersionScreenshotFromJson(Map<String, dynamic> json) =>
    VersionScreenshot(
      url: json['url'] as String,
      path: json['path'] as String,
      mimeType: json['mimeType'] as String,
      description: json['description'] as String?,
    );

Map<String, dynamic> _$VersionScreenshotToJson(VersionScreenshot instance) =>
    <String, dynamic>{
      'url': instance.url,
      'path': instance.path,
      'mimeType': instance.mimeType,
      'description': instance.description,
    };

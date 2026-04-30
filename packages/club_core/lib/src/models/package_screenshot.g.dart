// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_screenshot.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageScreenshot _$PackageScreenshotFromJson(Map<String, dynamic> json) =>
    PackageScreenshot(
      path: json['path'] as String,
      description: json['description'] as String?,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      sha256: json['sha256'] as String,
      mimeType: json['mimeType'] as String,
    );

Map<String, dynamic> _$PackageScreenshotToJson(PackageScreenshot instance) =>
    <String, dynamic>{
      'path': instance.path,
      'description': instance.description,
      'sizeBytes': instance.sizeBytes,
      'sha256': instance.sha256,
      'mimeType': instance.mimeType,
    };

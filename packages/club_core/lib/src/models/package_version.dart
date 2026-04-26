import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'package_screenshot.dart';

part 'package_version.g.dart';

@JsonSerializable()
class PackageVersion extends Equatable {
  const PackageVersion({
    required this.packageName,
    required this.version,
    required this.pubspecJson,
    this.readmeContent,
    this.changelogContent,
    this.exampleContent,
    this.examplePath,
    required this.libraries,
    this.binExecutables = const [],
    this.screenshots = const [],
    required this.archiveSizeBytes,
    required this.archiveSha256,
    this.uploaderId,
    this.publisherId,
    this.isRetracted = false,
    this.retractedAt,
    this.isPrerelease = false,
    this.dartSdkMin,
    this.dartSdkMax,
    this.flutterSdkMin,
    this.flutterSdkMax,
    this.tags = const [],
    required this.publishedAt,
  });

  factory PackageVersion.fromJson(Map<String, dynamic> json) =>
      _$PackageVersionFromJson(json);

  final String packageName;
  final String version;
  final String pubspecJson;
  final String? readmeContent;
  final String? changelogContent;
  final String? exampleContent;

  /// In-archive path of the extracted example file (e.g. `example/main.dart`).
  /// Tells the frontend how to render the content (markdown vs Dart code).
  final String? examplePath;

  final List<String> libraries;

  /// Command names for Dart files found directly under `bin/` in the archive.
  /// Populated at publish time so the frontend can show "Use as executable"
  /// even for packages that don't declare `executables:` in pubspec.yaml.
  final List<String> binExecutables;

  /// Screenshots declared via `screenshots:` in pubspec.yaml (pub spec v2).
  /// Image bytes live in the blob store; this list is the metadata index.
  /// Order matches the pubspec declaration — used as the carousel order.
  final List<PackageScreenshot> screenshots;

  final int archiveSizeBytes;
  final String archiveSha256;
  final String? uploaderId;
  final String? publisherId;
  final bool isRetracted;
  final DateTime? retractedAt;
  final bool isPrerelease;
  final String? dartSdkMin;
  final String? dartSdkMax;
  final String? flutterSdkMin;
  final String? flutterSdkMax;

  /// Derived SDK and platform tags (e.g. `sdk:dart`, `platform:android`).
  final List<String> tags;

  final DateTime publishedAt;

  Map<String, dynamic> get pubspecMap {
    final decoded = jsonDecode(pubspecJson);
    return Map<String, dynamic>.from(decoded as Map);
  }

  String get description => (pubspecMap['description'] as String?) ?? '';

  Map<String, dynamic> toJson() => _$PackageVersionToJson(this);

  @override
  List<Object?> get props => [packageName, version];
}

class PackageVersionCompanion {
  const PackageVersionCompanion({
    required this.packageName,
    required this.version,
    required this.pubspecJson,
    this.readmeContent,
    this.changelogContent,
    this.exampleContent,
    this.examplePath,
    required this.libraries,
    this.binExecutables = const [],
    this.screenshots = const [],
    required this.archiveSizeBytes,
    required this.archiveSha256,
    this.uploaderId,
    this.publisherId,
    this.isRetracted,
    this.retractedAt,
    this.isPrerelease = false,
    this.dartSdkMin,
    this.dartSdkMax,
    this.flutterSdkMin,
    this.flutterSdkMax,
    this.tags = const [],
  });

  final String packageName;
  final String version;
  final String pubspecJson;
  final String? readmeContent;
  final String? changelogContent;
  final String? exampleContent;
  final String? examplePath;
  final List<String> libraries;
  final List<String> binExecutables;
  final List<PackageScreenshot> screenshots;
  final int archiveSizeBytes;
  final String archiveSha256;
  final String? uploaderId;
  final String? publisherId;
  final bool? isRetracted;
  final DateTime? retractedAt;
  final bool isPrerelease;
  final String? dartSdkMin;
  final String? dartSdkMax;
  final String? flutterSdkMin;
  final String? flutterSdkMax;
  final List<String> tags;
}

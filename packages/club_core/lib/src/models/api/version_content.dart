import 'package:json_annotation/json_annotation.dart';

part 'version_content.g.dart';

/// Response shape for `GET /api/packages/<pkg>/versions/<ver>/content` and
/// `GET /api/packages/<pkg>/content` (latest).
///
/// Carries the markdown bodies of README, CHANGELOG, and example along with
/// any screenshots and bin executables declared at publish time. Asset URLs
/// embedded in [readme] are already rewritten to absolute server URLs by the
/// publish-time README rewriter.
@JsonSerializable()
class VersionContent {
  const VersionContent({
    required this.package,
    required this.version,
    this.readme,
    this.changelog,
    this.example,
    this.examplePath,
    this.binExecutables = const [],
    this.screenshots = const [],
  });

  factory VersionContent.fromJson(Map<String, dynamic> json) =>
      _$VersionContentFromJson(json);

  final String package;
  final String version;
  final String? readme;
  final String? changelog;
  final String? example;
  final String? examplePath;
  final List<String> binExecutables;
  final List<VersionScreenshot> screenshots;

  Map<String, dynamic> toJson() => _$VersionContentToJson(this);
}

@JsonSerializable()
class VersionScreenshot {
  const VersionScreenshot({
    required this.url,
    required this.path,
    required this.mimeType,
    this.description,
  });

  factory VersionScreenshot.fromJson(Map<String, dynamic> json) =>
      _$VersionScreenshotFromJson(json);

  final String url;
  final String path;
  final String mimeType;
  final String? description;

  Map<String, dynamic> toJson() => _$VersionScreenshotToJson(this);
}

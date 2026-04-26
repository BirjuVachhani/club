import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'package_screenshot.g.dart';

/// Lower-cased file extension of a screenshot path (without the leading
/// dot). Returns an empty string when no extension is present. Centralised
/// here because publish extraction, the persistence layer, and the HTTP
/// route all derive the on-disk filename from this same rule.
String screenshotExtOf(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < slash) return '';
  return path.substring(dot + 1).toLowerCase();
}

/// A screenshot declared in a package's `pubspec.yaml` under the
/// `screenshots:` key (pub spec v2). Stored per-version as a JSON array
/// in `package_versions.screenshots` and as image bytes in the blob store
/// under the asset key `screenshots/<version>/<index>.<ext>`.
@JsonSerializable()
class PackageScreenshot extends Equatable {
  const PackageScreenshot({
    required this.path,
    this.description,
    required this.sizeBytes,
    required this.sha256,
    required this.mimeType,
  });

  factory PackageScreenshot.fromJson(Map<String, dynamic> json) =>
      _$PackageScreenshotFromJson(json);

  /// Original in-archive path as declared in pubspec.yaml
  /// (e.g. `screenshots/home_light.png`). Kept verbatim so the admin UI
  /// can show what the author wrote.
  final String path;

  /// Optional caption from pubspec.yaml. Shown in the fullscreen carousel.
  final String? description;

  final int sizeBytes;
  final String sha256;

  /// IANA media type inferred from the file extension at publish time.
  /// One of: image/png, image/jpeg, image/gif, image/webp.
  final String mimeType;

  Map<String, dynamic> toJson() => _$PackageScreenshotToJson(this);

  @override
  List<Object?> get props => [path, description, sizeBytes, sha256, mimeType];
}

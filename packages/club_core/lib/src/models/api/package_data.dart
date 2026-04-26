import 'package:json_annotation/json_annotation.dart';

import 'version_info.dart';

part 'package_data.g.dart';

/// Response for `GET /api/packages/<package>`.
/// Used by `dart pub get` for dependency resolution.
@JsonSerializable()
class PackageData {
  const PackageData({
    required this.name,
    this.isDiscontinued,
    this.replacedBy,
    this.isUnlisted,
    required this.latest,
    this.latestPrerelease,
    required this.versions,
  });

  factory PackageData.fromJson(Map<String, dynamic> json) =>
      _$PackageDataFromJson(json);

  final String name;
  final bool? isDiscontinued;
  final String? replacedBy;
  final bool? isUnlisted;
  final VersionInfo latest;

  /// Set only when a prerelease version is strictly greater than
  /// [latest] (semver comparison via `pub_semver`). Null otherwise.
  final VersionInfo? latestPrerelease;

  final List<VersionInfo> versions;

  Map<String, dynamic> toJson() => _$PackageDataToJson(this);
}

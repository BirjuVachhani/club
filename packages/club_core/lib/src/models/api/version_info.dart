import 'package:json_annotation/json_annotation.dart';

part 'version_info.g.dart';

/// Version metadata in the pub spec v2 format.
@JsonSerializable()
class VersionInfo {
  const VersionInfo({
    required this.version,
    this.retracted,
    required this.pubspec,
    this.archiveUrl,
    this.archiveSha256,
    this.published,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) =>
      _$VersionInfoFromJson(json);

  final String version;
  final bool? retracted;
  final Map<String, dynamic> pubspec;

  @JsonKey(name: 'archive_url')
  final String? archiveUrl;

  @JsonKey(name: 'archive_sha256')
  final String? archiveSha256;

  final DateTime? published;

  Map<String, dynamic> toJson() => _$VersionInfoToJson(this);
}

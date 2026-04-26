import 'package:json_annotation/json_annotation.dart';

part 'upload_info.g.dart';

/// Response for `GET /api/packages/versions/new`.
/// Tells the pub client where to upload the tarball.
@JsonSerializable()
class UploadInfo {
  const UploadInfo({required this.url, required this.fields});

  factory UploadInfo.fromJson(Map<String, dynamic> json) =>
      _$UploadInfoFromJson(json);

  final String url;
  final Map<String, String> fields;

  Map<String, dynamic> toJson() => _$UploadInfoToJson(this);
}

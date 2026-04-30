import 'package:json_annotation/json_annotation.dart';

part 'version_options.g.dart';

/// Options on a specific package version (retracted).
@JsonSerializable()
class VersionOptions {
  const VersionOptions({this.isRetracted});

  factory VersionOptions.fromJson(Map<String, dynamic> json) =>
      _$VersionOptionsFromJson(json);

  final bool? isRetracted;

  Map<String, dynamic> toJson() => _$VersionOptionsToJson(this);
}

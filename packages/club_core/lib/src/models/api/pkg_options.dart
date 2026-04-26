import 'package:json_annotation/json_annotation.dart';

part 'pkg_options.g.dart';

/// Options and flags on a package (discontinued, unlisted).
@JsonSerializable()
class PkgOptions {
  const PkgOptions({this.isDiscontinued, this.replacedBy, this.isUnlisted});

  factory PkgOptions.fromJson(Map<String, dynamic> json) =>
      _$PkgOptionsFromJson(json);

  final bool? isDiscontinued;
  final String? replacedBy;
  final bool? isUnlisted;

  Map<String, dynamic> toJson() => _$PkgOptionsToJson(this);
}

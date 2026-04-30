import 'package:json_annotation/json_annotation.dart';

part 'package_publisher_info.g.dart';

/// Publisher ownership info for a package.
@JsonSerializable()
class PackagePublisherInfo {
  const PackagePublisherInfo({this.publisherId});

  factory PackagePublisherInfo.fromJson(Map<String, dynamic> json) =>
      _$PackagePublisherInfoFromJson(json);

  final String? publisherId;

  Map<String, dynamic> toJson() => _$PackagePublisherInfoToJson(this);
}

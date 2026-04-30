import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'package.g.dart';

@JsonSerializable()
class Package extends Equatable {
  const Package({
    required this.name,
    this.publisherId,
    this.latestVersion,
    this.latestPrerelease,
    this.likesCount = 0,
    this.isDiscontinued = false,
    this.replacedBy,
    this.isUnlisted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Package.fromJson(Map<String, dynamic> json) =>
      _$PackageFromJson(json);

  final String name;
  final String? publisherId;
  final String? latestVersion;
  final String? latestPrerelease;
  final int likesCount;
  final bool isDiscontinued;
  final String? replacedBy;
  final bool isUnlisted;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isOwnedByPublisher => publisherId != null;

  Map<String, dynamic> toJson() => _$PackageToJson(this);

  @override
  List<Object?> get props => [
    name,
    publisherId,
    latestVersion,
    latestPrerelease,
    likesCount,
    isDiscontinued,
    replacedBy,
    isUnlisted,
    createdAt,
    updatedAt,
  ];
}

class PackageCompanion {
  const PackageCompanion({
    required this.name,
    this.publisherId,
    this.latestVersion,
    this.latestPrerelease,
    this.likesCount,
    this.isDiscontinued,
    this.replacedBy,
    this.isUnlisted,
  });

  final String name;
  final String? publisherId;
  final String? latestVersion;
  final String? latestPrerelease;
  final int? likesCount;
  final bool? isDiscontinued;
  final String? replacedBy;
  final bool? isUnlisted;
}

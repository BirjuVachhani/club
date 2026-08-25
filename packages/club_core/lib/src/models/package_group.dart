import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'package_group.g.dart';

/// A visual collection of related packages.
///
/// Groups never own packages or grant package permissions. Exactly one of
/// [ownerUserId] and [publisherId] is set and controls group management only.
@JsonSerializable()
class PackageGroup extends Equatable {
  const PackageGroup({
    required this.id,
    required this.slug,
    required this.name,
    this.description,
    this.ownerUserId,
    this.publisherId,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  }) : assert(
         (ownerUserId == null) != (publisherId == null),
         'A package group must have exactly one user or publisher owner.',
       );

  factory PackageGroup.fromJson(Map<String, dynamic> json) =>
      _$PackageGroupFromJson(json);

  final String id;
  final String slug;
  final String name;
  final String? description;
  final String? ownerUserId;
  final String? publisherId;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isPublisherOwned => publisherId != null;

  Map<String, dynamic> toJson() => _$PackageGroupToJson(this);

  @override
  List<Object?> get props => [id];
}

/// Values required to create a package group.
class PackageGroupCompanion {
  const PackageGroupCompanion({
    required this.id,
    required this.slug,
    required this.name,
    this.description,
    this.ownerUserId,
    this.publisherId,
    required this.createdBy,
  }) : assert(
         (ownerUserId == null) != (publisherId == null),
         'A package group must have exactly one user or publisher owner.',
       );

  final String id;
  final String slug;
  final String name;
  final String? description;
  final String? ownerUserId;
  final String? publisherId;
  final String createdBy;
}

/// One package's ordered membership in a group.
@JsonSerializable()
class PackageGroupPackage extends Equatable {
  const PackageGroupPackage({
    required this.groupId,
    required this.packageName,
    required this.position,
    this.addedBy,
    required this.createdAt,
  });

  factory PackageGroupPackage.fromJson(Map<String, dynamic> json) =>
      _$PackageGroupPackageFromJson(json);

  final String groupId;
  final String packageName;
  final int position;
  final String? addedBy;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => _$PackageGroupPackageToJson(this);

  @override
  List<Object?> get props => [groupId, packageName];
}

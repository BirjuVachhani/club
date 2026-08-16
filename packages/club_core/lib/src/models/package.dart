import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'package_visibility.dart';

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
    this.visibility = PackageVisibility.private,
    this.visibilityChangedAt,
    this.visibilityChangedBy,
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

  /// Whether this package is readable without credentials. Defaults to
  /// [PackageVisibility.private] so a package that is constructed without
  /// an explicit decision is never exposed.
  final PackageVisibility visibility;

  /// When [visibility] last changed, and who changed it. Both null for a
  /// package that has never been flipped. The audit log carries the full
  /// history; these two exist so the UI can show "made public by X on Y"
  /// without a log query on every package page.
  final DateTime? visibilityChangedAt;
  final String? visibilityChangedBy;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isOwnedByPublisher => publisherId != null;

  bool get isPublic => visibility.isPublic;

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
    visibility,
    visibilityChangedAt,
    visibilityChangedBy,
    createdAt,
    updatedAt,
  ];
}

/// Write DTO for `packages`. Every field is nullable and `updatePackage`
/// null-coalesces against the existing row, so a null means "leave alone",
/// not "set to null".
///
/// That is load-bearing for [visibility]: `PublishService.finalize` creates
/// a new package with a bare `PackageCompanion(name: name)`, which relies on
/// the SQL default (`'private'`) for a new row and leaves an existing row's
/// visibility untouched on republish. Do not "fix" this into a non-null
/// field with a default — that would silently reset visibility on any
/// update that forgot to pass it, and the direction it would reset *to*
/// is the only thing keeping that safe.
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
    this.visibility,
    this.visibilityChangedAt,
    this.visibilityChangedBy,
  });

  final String name;
  final String? publisherId;
  final String? latestVersion;
  final String? latestPrerelease;
  final int? likesCount;
  final bool? isDiscontinued;
  final String? replacedBy;
  final bool? isUnlisted;

  /// Only `VisibilityService` should set these. Flipping visibility has
  /// consequences beyond this row (recomputing `public_resolvable` for
  /// dependents, audit records, reverse-dependency checks), so a bare
  /// `updatePackage` that sets it directly would leave the database
  /// internally inconsistent.
  final PackageVisibility? visibility;
  final DateTime? visibilityChangedAt;
  final String? visibilityChangedBy;
}

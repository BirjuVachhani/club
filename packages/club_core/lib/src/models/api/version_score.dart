import 'package:json_annotation/json_annotation.dart';

part 'version_score.g.dart';

/// Package scoring data. Stub in v1 (no pana analysis).
@JsonSerializable(includeIfNull: true)
class VersionScore {
  const VersionScore({
    this.grantedPoints,
    this.maxPoints,
    this.likeCount,
    this.downloadCount30Days,
    this.tags,
  });

  factory VersionScore.fromJson(Map<String, dynamic> json) =>
      _$VersionScoreFromJson(json);

  final int? grantedPoints;
  final int? maxPoints;
  final int? likeCount;
  final int? downloadCount30Days;
  final List<String>? tags;

  /// Create a stub score with just the like count.
  // ignore: sort_constructors_first
  factory VersionScore.stub({int likeCount = 0}) => VersionScore(
    grantedPoints: 0,
    maxPoints: 0,
    likeCount: likeCount,
    downloadCount30Days: 0,
    tags: const [],
  );

  Map<String, dynamic> toJson() => _$VersionScoreToJson(this);
}

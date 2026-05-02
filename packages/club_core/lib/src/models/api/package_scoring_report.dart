import 'package:json_annotation/json_annotation.dart';

part 'package_scoring_report.g.dart';

/// Response shape for `GET /api/packages/<pkg>/versions/<ver>/scoring-report`.
///
/// The server returns one of several states: `disabled` (scoring turned off
/// system-wide), `not_analyzed` (never queued), `pending`/`running` (worker
/// in flight), `failed`, or `completed` (with the parsed pana sections).
@JsonSerializable()
class PackageScoringReport {
  const PackageScoringReport({
    required this.status,
    this.grantedPoints,
    this.maxPoints,
    this.sections = const [],
    this.panaVersion,
    this.dartVersion,
    this.flutterVersion,
    this.analyzedAt,
    this.errorMessage,
  });

  factory PackageScoringReport.fromJson(Map<String, dynamic> json) =>
      _$PackageScoringReportFromJson(json);

  /// `disabled`, `not_analyzed`, `pending`, `running`, `failed`, `completed`.
  final String status;
  final int? grantedPoints;
  final int? maxPoints;
  final List<ScoringSection> sections;
  final String? panaVersion;
  final String? dartVersion;
  final String? flutterVersion;
  final DateTime? analyzedAt;
  final String? errorMessage;

  bool get isCompleted => status == 'completed';

  Map<String, dynamic> toJson() => _$PackageScoringReportToJson(this);
}

@JsonSerializable()
class ScoringSection {
  const ScoringSection({
    required this.id,
    required this.title,
    this.grantedPoints,
    this.maxPoints,
    this.status,
    this.summary,
  });

  factory ScoringSection.fromJson(Map<String, dynamic> json) =>
      _$ScoringSectionFromJson(json);

  final String id;
  final String title;
  final int? grantedPoints;
  final int? maxPoints;
  final String? status;
  final String? summary;

  Map<String, dynamic> toJson() => _$ScoringSectionToJson(this);
}

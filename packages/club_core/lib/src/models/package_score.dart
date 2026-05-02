/// Score status for a package version's pana analysis.
enum ScoreStatus {
  /// Analysis has been queued but not yet started.
  pending,

  /// Analysis is currently running.
  running,

  /// Analysis completed successfully.
  completed,

  /// Analysis failed.
  failed
  ;

  static ScoreStatus fromString(String value) => ScoreStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ScoreStatus.pending,
  );
}

/// Persisted pana analysis result for a package version.
class PackageScore {
  const PackageScore({
    required this.packageName,
    required this.version,
    required this.status,
    this.grantedPoints,
    this.maxPoints,
    this.reportJson,
    this.panaTags = const [],
    this.panaVersion,
    this.dartVersion,
    this.flutterVersion,
    this.errorMessage,
    this.scoredAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String packageName;
  final String version;
  final ScoreStatus status;
  final int? grantedPoints;
  final int? maxPoints;

  /// Full pana report JSON (contains sections with markdown summaries).
  final String? reportJson;

  /// Tag set emitted by pana (`sdk:flutter`, `is:wasm-ready`, etc.).
  /// Cached on the score row so [PackageService.getScore] can merge it
  /// with publish-time tags without parsing [reportJson] on every read.
  /// Empty until the next pana run repopulates it.
  final List<String> panaTags;

  final String? panaVersion;
  final String? dartVersion;
  final String? flutterVersion;
  final String? errorMessage;
  final DateTime? scoredAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Write companion for creating/updating a package score row.
class PackageScoreCompanion {
  const PackageScoreCompanion({
    required this.packageName,
    required this.version,
    required this.status,
    this.grantedPoints,
    this.maxPoints,
    this.reportJson,
    this.panaTags = const [],
    this.panaVersion,
    this.dartVersion,
    this.flutterVersion,
    this.errorMessage,
    this.scoredAt,
  });

  final String packageName;
  final String version;
  final ScoreStatus status;
  final int? grantedPoints;
  final int? maxPoints;
  final String? reportJson;
  final List<String> panaTags;
  final String? panaVersion;
  final String? dartVersion;
  final String? flutterVersion;
  final String? errorMessage;
  final DateTime? scoredAt;
}

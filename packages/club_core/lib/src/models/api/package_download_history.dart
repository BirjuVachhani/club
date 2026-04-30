import 'package:json_annotation/json_annotation.dart';

part 'package_download_history.g.dart';

/// A single weekly bucket with per-version download counts.
@JsonSerializable()
class DownloadWeek {
  const DownloadWeek({
    required this.weekStart,
    required this.weekLabel,
    required this.total,
    required this.byVersion,
  });

  factory DownloadWeek.fromJson(Map<String, dynamic> json) =>
      _$DownloadWeekFromJson(json);

  /// Monday of the week, 'YYYY-MM-DD'.
  final String weekStart;

  /// Human-readable label, e.g. 'Apr 14'.
  final String weekLabel;

  /// Total downloads across all versions for this week.
  final int total;

  /// Per-version breakdown: version string -> count.
  final Map<String, int> byVersion;

  Map<String, dynamic> toJson() => _$DownloadWeekToJson(this);
}

/// Response shape for `GET /api/packages/<pkg>/downloads`.
@JsonSerializable()
class PackageDownloadHistory {
  const PackageDownloadHistory({
    required this.packageName,
    required this.total30Days,
    required this.weeks,
  });

  factory PackageDownloadHistory.fromJson(Map<String, dynamic> json) =>
      _$PackageDownloadHistoryFromJson(json);

  final String packageName;
  final int total30Days;

  /// Weekly buckets ordered oldest-to-newest (always [weeks] entries).
  final List<DownloadWeek> weeks;

  Map<String, dynamic> toJson() => _$PackageDownloadHistoryToJson(this);
}

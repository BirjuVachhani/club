import 'package:json_annotation/json_annotation.dart';

part 'database_stats.g.dart';

/// One entry in the database's storage breakdown: a table, an index, or an
/// engine-internal relation (FTS shadow tables and the like).
@JsonSerializable()
class DbTableStat {
  const DbTableStat({
    required this.name,
    required this.bytes,
    required this.isIndex,
    this.rows,
  });

  factory DbTableStat.fromJson(Map<String, dynamic> json) =>
      _$DbTableStatFromJson(json);

  /// Relation name as the engine reports it.
  final String name;

  /// Space this relation occupies, including its own overhead.
  final int bytes;

  /// Whether this entry is an index rather than a table. Indexes are listed
  /// alongside tables because they can easily outweigh the data they cover.
  final bool isIndex;

  /// Row count, or null when counting is not applicable (indexes) or not
  /// available on the backend.
  final int? rows;

  Map<String, dynamic> toJson() => _$DbTableStatToJson(this);
}

/// Storage stats reported by the database engine itself.
///
/// Deliberately backend-neutral: every field maps onto both SQLite (page
/// arithmetic plus `dbstat`) and PostgreSQL (`pg_database_size` plus the
/// `pg_class` catalog), so a future Postgres [MetadataStore] fills these in
/// without the admin API or the frontend changing.
@JsonSerializable()
class DatabaseStats {
  const DatabaseStats({
    required this.totalBytes,
    required this.tables,
    this.reclaimableBytes,
  });

  factory DatabaseStats.fromJson(Map<String, dynamic> json) =>
      _$DatabaseStatsFromJson(json);

  /// Total size the engine reports for the database.
  ///
  /// This is the engine's own accounting, which can differ slightly from the
  /// database's on-disk footprint (the admin stats endpoint reports that
  /// separately, and for SQLite it also covers the `-wal` / `-shm` sidecars).
  final int totalBytes;

  /// Space already allocated but not in use, and therefore recoverable by a
  /// `VACUUM`. Null when the backend cannot report it.
  final int? reclaimableBytes;

  /// Largest relations first. Truncated to the caller's requested limit, so
  /// this is a top-N list rather than the full catalog.
  final List<DbTableStat> tables;

  Map<String, dynamic> toJson() => _$DatabaseStatsToJson(this);
}

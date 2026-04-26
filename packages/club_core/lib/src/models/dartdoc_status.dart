/// Status of dartdoc generation for a package.
enum DartdocStatus {
  pending,
  running,
  completed,
  failed
  ;

  static DartdocStatus fromString(String value) =>
      DartdocStatus.values.firstWhere(
        (e) => e.name == value,
        orElse: () => DartdocStatus.pending,
      );
}

/// Persisted dartdoc generation record for a package.
/// One row per package — only the latest version's docs are kept.
class DartdocRecord {
  const DartdocRecord({
    required this.packageName,
    required this.version,
    required this.status,
    this.errorMessage,
    this.generatedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String packageName;
  final String version;
  final DartdocStatus status;
  final String? errorMessage;
  final DateTime? generatedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Write companion for creating/updating a dartdoc status row.
class DartdocRecordCompanion {
  const DartdocRecordCompanion({
    required this.packageName,
    required this.version,
    required this.status,
    this.errorMessage,
    this.generatedAt,
  });

  final String packageName;
  final String version;
  final DartdocStatus status;
  final String? errorMessage;
  final DateTime? generatedAt;
}

import 'package:json_annotation/json_annotation.dart';

part 'package_dartdoc_status.g.dart';

/// Response shape for `GET /api/packages/<pkg>/dartdoc-status`.
///
/// `not_generated` is returned when the package has never been queued for
/// scoring; `pending`/`running`/`completed`/`failed` mirror the worker's
/// internal state machine. [docsUrl] is set only when [status] is
/// `completed` and is a server-relative path (e.g. `/documentation/foo/latest/`).
@JsonSerializable()
class PackageDartdocStatus {
  const PackageDartdocStatus({
    required this.status,
    this.version,
    this.generatedAt,
    this.docsUrl,
    this.errorMessage,
  });

  factory PackageDartdocStatus.fromJson(Map<String, dynamic> json) =>
      _$PackageDartdocStatusFromJson(json);

  /// One of `not_generated`, `pending`, `running`, `completed`, `failed`.
  final String status;
  final String? version;
  final DateTime? generatedAt;

  /// Server-relative URL to the rendered dartdoc index, set only when
  /// [status] is `completed`.
  final String? docsUrl;
  final String? errorMessage;

  bool get isReady => status == 'completed' && docsUrl != null;

  Map<String, dynamic> toJson() => _$PackageDartdocStatusToJson(this);
}

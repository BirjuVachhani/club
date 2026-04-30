import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'audit_log.g.dart';

@JsonSerializable()
class AuditLogRecord extends Equatable {
  const AuditLogRecord({
    required this.id,
    required this.createdAt,
    required this.kind,
    this.agentId,
    this.packageName,
    this.version,
    this.publisherId,
    required this.summary,
    required this.dataJson,
  });

  factory AuditLogRecord.fromJson(Map<String, dynamic> json) =>
      _$AuditLogRecordFromJson(json);

  final String id;
  final DateTime createdAt;
  final String kind;
  final String? agentId;
  final String? packageName;
  final String? version;
  final String? publisherId;
  final String summary;
  final String dataJson;

  Map<String, dynamic> toJson() => _$AuditLogRecordToJson(this);

  @override
  List<Object?> get props => [id];
}

class AuditLogCompanion {
  const AuditLogCompanion({
    required this.id,
    required this.kind,
    this.agentId,
    this.packageName,
    this.version,
    this.publisherId,
    required this.summary,
    this.dataJson = '{}',
  });

  final String id;
  final String kind;
  final String? agentId;
  final String? packageName;
  final String? version;
  final String? publisherId;
  final String summary;
  final String dataJson;
}

/// Well-known audit log event kinds.
abstract final class AuditKind {
  static const packageCreated = 'package.created';
  static const versionPublished = 'package.version_published';
  static const versionRetracted = 'package.version_retracted';
  static const versionUnretracted = 'package.version_unretracted';
  static const packageDiscontinued = 'package.discontinued';
  static const packageOptionsUpdated = 'package.options_updated';
  static const uploaderAdded = 'package.uploader_added';
  static const uploaderRemoved = 'package.uploader_removed';
  static const publisherChanged = 'package.publisher_changed';
  static const packageDeleted = 'package.deleted';
  static const publisherCreated = 'publisher.created';
  static const publisherVerified = 'publisher.verified';
  static const publisherUpdated = 'publisher.updated';
  static const publisherDeleted = 'publisher.deleted';
  static const memberAdded = 'publisher.member_added';
  static const memberRemoved = 'publisher.member_removed';
  static const userCreated = 'user.created';
  static const userUpdated = 'user.updated';
  static const userLogin = 'user.login';
  static const userDisabled = 'user.disabled';
  static const tokenCreated = 'user.token_created';
  static const tokenRevoked = 'user.token_revoked';
  static const versionScored = 'package.version_scored';
  static const versionScoreFailed = 'package.version_score_failed';
  static const dartdocGenerated = 'package.dartdoc_generated';
  static const dartdocFailed = 'package.dartdoc_failed';
}

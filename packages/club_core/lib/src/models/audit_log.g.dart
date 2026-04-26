// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'audit_log.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AuditLogRecord _$AuditLogRecordFromJson(Map<String, dynamic> json) =>
    AuditLogRecord(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      kind: json['kind'] as String,
      agentId: json['agentId'] as String?,
      packageName: json['packageName'] as String?,
      version: json['version'] as String?,
      publisherId: json['publisherId'] as String?,
      summary: json['summary'] as String,
      dataJson: json['dataJson'] as String,
    );

Map<String, dynamic> _$AuditLogRecordToJson(AuditLogRecord instance) =>
    <String, dynamic>{
      'id': instance.id,
      'createdAt': instance.createdAt.toIso8601String(),
      'kind': instance.kind,
      'agentId': instance.agentId,
      'packageName': instance.packageName,
      'version': instance.version,
      'publisherId': instance.publisherId,
      'summary': instance.summary,
      'dataJson': instance.dataJson,
    };

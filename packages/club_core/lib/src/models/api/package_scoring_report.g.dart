// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'package_scoring_report.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PackageScoringReport _$PackageScoringReportFromJson(
  Map<String, dynamic> json,
) => PackageScoringReport(
  status: json['status'] as String,
  grantedPoints: (json['grantedPoints'] as num?)?.toInt(),
  maxPoints: (json['maxPoints'] as num?)?.toInt(),
  sections:
      (json['sections'] as List<dynamic>?)
          ?.map((e) => ScoringSection.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  panaVersion: json['panaVersion'] as String?,
  dartVersion: json['dartVersion'] as String?,
  flutterVersion: json['flutterVersion'] as String?,
  analyzedAt: json['analyzedAt'] == null
      ? null
      : DateTime.parse(json['analyzedAt'] as String),
  errorMessage: json['errorMessage'] as String?,
);

Map<String, dynamic> _$PackageScoringReportToJson(
  PackageScoringReport instance,
) => <String, dynamic>{
  'status': instance.status,
  'grantedPoints': instance.grantedPoints,
  'maxPoints': instance.maxPoints,
  'sections': instance.sections,
  'panaVersion': instance.panaVersion,
  'dartVersion': instance.dartVersion,
  'flutterVersion': instance.flutterVersion,
  'analyzedAt': instance.analyzedAt?.toIso8601String(),
  'errorMessage': instance.errorMessage,
};

ScoringSection _$ScoringSectionFromJson(Map<String, dynamic> json) =>
    ScoringSection(
      id: json['id'] as String,
      title: json['title'] as String,
      grantedPoints: (json['grantedPoints'] as num?)?.toInt(),
      maxPoints: (json['maxPoints'] as num?)?.toInt(),
      status: json['status'] as String?,
      summary: json['summary'] as String?,
    );

Map<String, dynamic> _$ScoringSectionToJson(ScoringSection instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'grantedPoints': instance.grantedPoints,
      'maxPoints': instance.maxPoints,
      'status': instance.status,
      'summary': instance.summary,
    };

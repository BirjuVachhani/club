// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'version_score.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

VersionScore _$VersionScoreFromJson(Map<String, dynamic> json) => VersionScore(
  grantedPoints: (json['grantedPoints'] as num?)?.toInt(),
  maxPoints: (json['maxPoints'] as num?)?.toInt(),
  likeCount: (json['likeCount'] as num?)?.toInt(),
  downloadCount30Days: (json['downloadCount30Days'] as num?)?.toInt(),
  tags: (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList(),
);

Map<String, dynamic> _$VersionScoreToJson(VersionScore instance) =>
    <String, dynamic>{
      'grantedPoints': instance.grantedPoints,
      'maxPoints': instance.maxPoints,
      'likeCount': instance.likeCount,
      'downloadCount30Days': instance.downloadCount30Days,
      'tags': instance.tags,
    };

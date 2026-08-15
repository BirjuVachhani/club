// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database_stats.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DbTableStat _$DbTableStatFromJson(Map<String, dynamic> json) => DbTableStat(
  name: json['name'] as String,
  bytes: (json['bytes'] as num).toInt(),
  isIndex: json['isIndex'] as bool,
  rows: (json['rows'] as num?)?.toInt(),
);

Map<String, dynamic> _$DbTableStatToJson(DbTableStat instance) =>
    <String, dynamic>{
      'name': instance.name,
      'bytes': instance.bytes,
      'isIndex': instance.isIndex,
      'rows': instance.rows,
    };

DatabaseStats _$DatabaseStatsFromJson(Map<String, dynamic> json) =>
    DatabaseStats(
      totalBytes: (json['totalBytes'] as num).toInt(),
      tables: (json['tables'] as List<dynamic>)
          .map((e) => DbTableStat.fromJson(e as Map<String, dynamic>))
          .toList(),
      reclaimableBytes: (json['reclaimableBytes'] as num?)?.toInt(),
    );

Map<String, dynamic> _$DatabaseStatsToJson(DatabaseStats instance) =>
    <String, dynamic>{
      'totalBytes': instance.totalBytes,
      'reclaimableBytes': instance.reclaimableBytes,
      'tables': instance.tables,
    };
